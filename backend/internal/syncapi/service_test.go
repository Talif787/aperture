package syncapi

import (
	"context"
	"errors"
	"testing"
	"time"

	"github.com/talif/aperture/backend/internal/tenancy"
)

const (
	tenantA = "11111111-1111-4111-a111-111111111111"
	tenantB = "22222222-2222-4222-a222-222222222222"
)

func fixedNow() func() time.Time {
	instant := time.Unix(1780000000, 0).UTC()
	return func() time.Time { return instant }
}

func scoped(tenantID string) context.Context {
	return tenancy.WithPrincipal(context.Background(), tenancy.Principal{
		TenantID: tenantID,
		UserID:   "user-1",
		Roles:    []string{"inspector"},
	})
}

func newService() (*Service, *InMemoryStore) {
	store := NewInMemoryStore(fixedNow())
	return NewService(store, fixedNow()), store
}

func operation(id, entityID string, base int64, fields ...string) Operation {
	return Operation{
		OperationID: id,
		EntityType:  "finding",
		EntityID:    entityID,
		Kind:        KindUpdate,
		DirtyFields: fields,
		BaseVersion: base,
		HLC:         "2026-09-10T00:26:40.123Z-0000-devA",
		Payload:     map[string]any{fields[0]: "value-" + id},
	}
}

func push(ctx context.Context, t *testing.T, service *Service, ops ...Operation) *PushResponse {
	t.Helper()
	response, err := service.Push(ctx, PushRequest{Operations: ops})
	if err != nil {
		t.Fatalf("push failed: %v", err)
	}
	return response
}

func TestCreateAppliesAtVersionOne(t *testing.T) {
	service, _ := newService()

	response := push(scoped(tenantA), t, service, Operation{
		OperationID: "op-1", EntityType: "finding", EntityID: "f-1", Kind: KindCreate,
		DirtyFields: []string{"note"}, BaseVersion: 0, HLC: "hlc-1",
		Payload: map[string]any{"note": "first"},
	})

	result := response.Results[0]
	if result.Status != StatusApplied || result.ServerVersion != 1 {
		t.Fatalf("unexpected result: %+v", result)
	}
}

func TestRetryReplaysRatherThanReapplying(t *testing.T) {
	service, store := newService()
	ctx := scoped(tenantA)
	op := operation("op-1", "f-1", 0, "note")

	first := push(ctx, t, service, op).Results[0]
	second := push(ctx, t, service, op).Results[0]

	// Exactly-once effect over an at-least-once channel. Without this, a retry after an
	// unknown outcome (the common case on a marginal link) applies the change twice.
	if first.Status != StatusApplied || second.Status != StatusReplayed {
		t.Fatalf("expected applied then replayed, got %s then %s", first.Status, second.Status)
	}
	if first.ServerVersion != second.ServerVersion {
		t.Fatalf("replay returned a different version: %d vs %d",
			first.ServerVersion, second.ServerVersion)
	}

	entity, err := store.Entity(ctx, "finding", "f-1")
	if err != nil {
		t.Fatalf("reading entity: %v", err)
	}
	if entity.Version != 1 {
		t.Fatalf("the operation was applied %d times, expected once", entity.Version)
	}
}

func TestConcurrentEditsToDifferentFieldsBothApply(t *testing.T) {
	service, _ := newService()
	ctx := scoped(tenantA)

	push(ctx, t, service, operation("op-1", "f-1", 0, "note"))

	// A second device still believes the entity is at version 1, but it changed a field
	// nobody else touched. This is concurrency, not disagreement, and prompting a person
	// for it would happen several times a shift for no reason.
	result := push(ctx, t, service, operation("op-2", "f-1", 0, "severity")).Results[0]

	if result.Status != StatusApplied {
		t.Fatalf("expected applied, got %+v", result)
	}
}

func TestOverlappingFieldConflicts(t *testing.T) {
	service, _ := newService()
	ctx := scoped(tenantA)

	push(ctx, t, service, operation("op-1", "f-1", 0, "measurement_value"))
	result := push(ctx, t, service, operation("op-2", "f-1", 0, "measurement_value")).Results[0]

	if result.Status != StatusConflict {
		t.Fatalf("expected conflict, got %+v", result)
	}
	if len(result.ConflictingFields) != 1 || result.ConflictingFields[0] != "measurement_value" {
		t.Fatalf("expected the field named, got %v", result.ConflictingFields)
	}
	if result.ServerVersion != 1 {
		t.Fatalf("a conflict must report the current server version, got %d", result.ServerVersion)
	}
}

func TestConflictIsStableAcrossRetries(t *testing.T) {
	service, _ := newService()
	ctx := scoped(tenantA)

	push(ctx, t, service, operation("op-1", "f-1", 0, "measurement_value"))
	op := operation("op-2", "f-1", 0, "measurement_value")

	first := push(ctx, t, service, op).Results[0]
	push(ctx, t, service, operation("op-3", "f-1", 1, "note"))
	second := push(ctx, t, service, op).Results[0]

	// The server has moved on between the two calls. A client retrying after a conflict
	// must receive the same conflict rather than a fresh evaluation, or the two sides can
	// disagree about what was decided.
	if first.Status != second.Status || first.ServerVersion != second.ServerVersion {
		t.Fatalf("conflict was re-evaluated: %+v then %+v", first, second)
	}
}

func TestOneRejectionDoesNotFailTheBatch(t *testing.T) {
	service, _ := newService()

	response := push(scoped(tenantA), t, service,
		operation("op-1", "f-1", 0, "note"),
		Operation{OperationID: "op-2", EntityType: "finding", EntityID: "f-2", Kind: "nonsense",
			DirtyFields: []string{"note"}, HLC: "hlc"},
		operation("op-3", "f-3", 0, "note"),
	)

	// A device with one poisoned operation would otherwise be unable to sync anything, and
	// the user has no way to identify or remove the offending record.
	if len(response.Results) != 3 {
		t.Fatalf("expected 3 results, got %d", len(response.Results))
	}
	if response.Results[0].Status != StatusApplied ||
		response.Results[1].Status != StatusRejected ||
		response.Results[2].Status != StatusApplied {
		t.Fatalf("unexpected statuses: %+v", response.Results)
	}
}

func TestOperationsMissingDirtyFieldsAreRejected(t *testing.T) {
	service, _ := newService()

	result := push(scoped(tenantA), t, service, Operation{
		OperationID: "op-1", EntityType: "finding", EntityID: "f-1",
		Kind: KindUpdate, BaseVersion: 0, HLC: "hlc",
	}).Results[0]

	// Without dirty fields the server can only compare versions, and every concurrent edit
	// becomes a whole-entity conflict that clobbers a field the sender never touched.
	if result.Status != StatusRejected || result.Retryable {
		t.Fatalf("expected a permanent rejection, got %+v", result)
	}
}

func TestEditingAnEntityTheServerHasNeverSeenConflicts(t *testing.T) {
	service, _ := newService()

	result := push(scoped(tenantA), t, service, operation("op-1", "f-unknown", 7, "note")).Results[0]

	// Usually a restore onto a different backend. Applying it would silently resurrect a
	// record that was deliberately removed.
	if result.Status != StatusConflict || result.Code != "ENTITY_MISSING" {
		t.Fatalf("expected ENTITY_MISSING, got %+v", result)
	}
}

func TestTenantsCannotSeeEachOther(t *testing.T) {
	service, _ := newService()

	push(scoped(tenantA), t, service, operation("op-1", "f-1", 0, "note"))

	// The same entity identifier, a different tenant. It must look absent, not conflict,
	// because a conflict would confirm that something exists under that identifier.
	result := push(scoped(tenantB), t, service, operation("op-2", "f-1", 0, "note")).Results[0]
	if result.Status != StatusApplied {
		t.Fatalf("tenant B should have created its own record, got %+v", result)
	}

	// This assertion was written and then thrown away with `_ = pulled`, so the suite
	// reported a passing tenant-isolation test while the change log was returning every
	// tenant's activity to every caller. A test that fetches a value and discards it is
	// worse than no test: it occupies the space where the real one would have gone.
	pulled, err := service.Pull(scoped(tenantB), PullRequest{})
	if err != nil {
		t.Fatalf("pull failed: %v", err)
	}
	if len(pulled.Changes) != 1 {
		t.Fatalf("tenant B saw %d changes, expected only its own", len(pulled.Changes))
	}

	fromA, err := service.Pull(scoped(tenantA), PullRequest{})
	if err != nil {
		t.Fatalf("pull failed: %v", err)
	}
	if len(fromA.Changes) != 1 {
		t.Fatalf("tenant A saw %d changes, expected only its own", len(fromA.Changes))
	}
}

func TestTheChangeLogIsScopedToTheTenant(t *testing.T) {
	service, _ := newService()

	for i := 0; i < 5; i++ {
		push(scoped(tenantA), t, service, operation("a-"+string(rune('a'+i)), "f-a"+string(rune('a'+i)), 0, "note"))
	}
	push(scoped(tenantB), t, service, operation("b-1", "f-b1", 0, "note"))

	fromB, err := service.Pull(scoped(tenantB), PullRequest{})
	if err != nil {
		t.Fatalf("pull failed: %v", err)
	}

	// Asserted on the count and on the identifiers, because a filter that happens to
	// return the right number of rows is not the same as one that returns the right rows.
	if len(fromB.Changes) != 1 {
		t.Fatalf("tenant B saw %d changes, expected 1", len(fromB.Changes))
	}
	if fromB.Changes[0].EntityID != "f-b1" {
		t.Fatalf("tenant B saw entity %q, which is not its own", fromB.Changes[0].EntityID)
	}
}

func TestCursorsAreIndependentAcrossTenants(t *testing.T) {
	service, _ := newService()

	push(scoped(tenantA), t, service, operation("a-1", "f-a1", 0, "note"))
	push(scoped(tenantA), t, service, operation("a-2", "f-a2", 0, "note"))
	push(scoped(tenantB), t, service, operation("b-1", "f-b1", 0, "note"))

	// Tenant B starts from the beginning and must see its own change, not skip past it
	// because tenant A happened to write two rows first. A cursor that counts rows rather
	// than naming a position is how a tenant silently loses its first changes.
	fromB, err := service.Pull(scoped(tenantB), PullRequest{})
	if err != nil {
		t.Fatalf("pull failed: %v", err)
	}
	if len(fromB.Changes) != 1 || fromB.Changes[0].EntityID != "f-b1" {
		t.Fatalf("tenant B got %+v", fromB.Changes)
	}
}

func TestIdempotencyKeysAreScopedToTheTenant(t *testing.T) {
	service, _ := newService()
	op := operation("shared-key", "f-1", 0, "note")

	push(scoped(tenantA), t, service, op)
	result := push(scoped(tenantB), t, service, op).Results[0]

	// A globally keyed idempotency table would return tenant A's stored response to
	// tenant B, which is both a correctness failure and a cross-tenant disclosure.
	if result.Status != StatusApplied {
		t.Fatalf("tenant B received tenant A's cached result: %+v", result)
	}
}

func TestUnscopedContextIsRefused(t *testing.T) {
	service, _ := newService()

	_, err := service.Push(context.Background(), PushRequest{
		Operations: []Operation{operation("op-1", "f-1", 0, "note")},
	})

	// The one failure that could cross a tenant boundary. It must be loud rather than
	// returning an empty result that looks like missing data.
	if !errors.Is(err, tenancy.ErrNoTenantInContext) {
		t.Fatalf("expected ErrNoTenantInContext, got %v", err)
	}
}

func TestPullPagesAndAdvancesTheCursor(t *testing.T) {
	service, _ := newService()
	ctx := scoped(tenantA)

	for i := 0; i < 5; i++ {
		push(ctx, t, service, operation("op-"+string(rune('a'+i)), "f-"+string(rune('a'+i)), 0, "note"))
	}

	first, err := service.Pull(ctx, PullRequest{Limit: 2})
	if err != nil {
		t.Fatalf("pull failed: %v", err)
	}
	if len(first.Changes) != 2 || !first.HasMore {
		t.Fatalf("unexpected first page: %d changes, hasMore=%v", len(first.Changes), first.HasMore)
	}

	second, err := service.Pull(ctx, PullRequest{Cursor: first.NextCursor, Limit: 2})
	if err != nil {
		t.Fatalf("pull failed: %v", err)
	}
	if len(second.Changes) != 2 {
		t.Fatalf("unexpected second page: %d", len(second.Changes))
	}

	final, err := service.Pull(ctx, PullRequest{Cursor: second.NextCursor, Limit: 2})
	if err != nil {
		t.Fatalf("pull failed: %v", err)
	}
	// HasMore is explicit rather than inferred from a short page, so an exactly-page-sized
	// final batch is not mistaken for a full one.
	if len(final.Changes) != 1 || final.HasMore {
		t.Fatalf("unexpected final page: %d changes, hasMore=%v", len(final.Changes), final.HasMore)
	}
}

func TestCursorBeyondTheEndIsNotAnError(t *testing.T) {
	service, _ := newService()

	response, err := service.Pull(scoped(tenantA), PullRequest{Cursor: "9999"})

	// Happens after a restore from backup. The device recovers on the next change rather
	// than being stuck reporting an error it cannot act on.
	if err != nil {
		t.Fatalf("expected no error, got %v", err)
	}
	if len(response.Changes) != 0 || response.HasMore {
		t.Fatalf("unexpected response: %+v", response)
	}
}

func TestMalformedCursorIsRejected(t *testing.T) {
	service, _ := newService()

	if _, err := service.Pull(scoped(tenantA), PullRequest{Cursor: "not-a-cursor"}); !errors.Is(err, ErrInvalidCursor) {
		t.Fatalf("expected ErrInvalidCursor, got %v", err)
	}
}

func TestBatchSizeIsBounded(t *testing.T) {
	service, _ := newService()

	operations := make([]Operation, MaxOperationsPerPush+1)
	for i := range operations {
		operations[i] = operation("op", "f-1", 0, "note")
	}

	_, err := service.Push(scoped(tenantA), PushRequest{Operations: operations})

	// A device dark for three days arrives with hundreds of operations. Unbounded batches
	// mean one timeout discards all of that progress.
	if !errors.Is(err, ErrBatchTooLarge) {
		t.Fatalf("expected ErrBatchTooLarge, got %v", err)
	}
}

func TestChangesAreEmptySliceNotNull(t *testing.T) {
	service, _ := newService()

	response, err := service.Pull(scoped(tenantA), PullRequest{})
	if err != nil {
		t.Fatalf("pull failed: %v", err)
	}

	// A client decoding null into a non-optional array crashes, and it is the kind of
	// crash that only happens on the one device that had nothing to pull.
	if response.Changes == nil {
		t.Fatal("changes must serialize as [] rather than null")
	}
}
