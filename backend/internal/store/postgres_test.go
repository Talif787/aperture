package store

import (
	"context"
	"os"
	"path/filepath"
	"sort"
	"testing"
	"time"

	"github.com/jackc/pgx/v5"

	"github.com/talif/aperture/backend/internal/syncapi"
	"github.com/talif/aperture/backend/internal/tenancy"
)

// These run against a real database or not at all.
//
// A mock of a database proves nothing about row-level security, which is the property this
// package exists to guarantee: the policies live in PostgreSQL, so only PostgreSQL can
// demonstrate they hold. Skipping without a database keeps the suite runnable everywhere
// while making the gap explicit rather than papering over it with a fake that always agrees.
const databaseURLVariable = "APERTURE_TEST_DATABASE_URL"

const (
	tenantA = "11111111-1111-4111-a111-111111111111"
	tenantB = "22222222-2222-4222-a222-222222222222"
)

func requireDatabase(t *testing.T) string {
	t.Helper()

	url := os.Getenv(databaseURLVariable)
	if url == "" {
		t.Skipf("set %s to run the store integration tests", databaseURLVariable)
	}
	return url
}

// newTestStore builds a schema, an application role, and a store connected as that role.
//
// Connecting as a NOSUPERUSER, NOBYPASSRLS role is the whole point. Superusers bypass row
// security regardless of FORCE ROW LEVEL SECURITY, so a test connected as one would pass
// every isolation assertion against policies that were never consulted.
func newTestStore(t *testing.T) (*Postgres, func()) {
	t.Helper()

	adminURL := requireDatabase(t)
	ctx := context.Background()

	admin, err := pgx.Connect(ctx, adminURL)
	if err != nil {
		t.Fatalf("connecting as admin: %v", err)
	}

	applyMigrations(t, ctx, admin)
	seedTenants(t, ctx, admin)
	appURL := ensureApplicationRole(t, ctx, admin, adminURL)

	if err := admin.Close(ctx); err != nil {
		t.Fatalf("closing admin connection: %v", err)
	}

	fixed := time.Unix(1780000000, 0).UTC()
	store, err := NewPostgres(ctx, appURL, func() time.Time { return fixed })
	if err != nil {
		t.Fatalf("opening store: %v", err)
	}

	return store, store.Close
}

func applyMigrations(t *testing.T, ctx context.Context, conn *pgx.Conn) {
	t.Helper()

	// Reset first. A test suite that depends on leftover state from a previous run fails
	// in ways nobody can reproduce, and the reproduction attempt starts from a clean
	// database.
	if _, err := conn.Exec(ctx, "DROP SCHEMA public CASCADE; CREATE SCHEMA public"); err != nil {
		t.Fatalf("resetting schema: %v", err)
	}

	var files []string
	for _, pattern := range []string{
		filepath.Join("..", "..", "migrations", "*.sql"),
		filepath.Join("..", "..", "..", "infra", "db", "*.sql"),
	} {
		matches, err := filepath.Glob(pattern)
		if err != nil {
			t.Fatalf("globbing %s: %v", pattern, err)
		}
		files = append(files, matches...)
	}

	// Ordered by file name, which is what the numeric prefixes are for. Ordering by
	// directory would apply grants before the tables they reference exist.
	sort.Slice(files, func(i, j int) bool {
		return filepath.Base(files[i]) < filepath.Base(files[j])
	})

	if len(files) == 0 {
		t.Fatal("no migration files found; run from backend/internal/store")
	}

	for _, file := range files {
		sql, err := os.ReadFile(file) // #nosec G304 -- paths come from a glob of the repository
		if err != nil {
			t.Fatalf("reading %s: %v", file, err)
		}
		if _, err := conn.Exec(ctx, string(sql)); err != nil {
			t.Fatalf("applying %s: %v", filepath.Base(file), err)
		}
	}
}

func seedTenants(t *testing.T, ctx context.Context, conn *pgx.Conn) {
	t.Helper()

	const insert = `
		INSERT INTO tenants (id, name, oidc_issuer, oidc_client_id, email_domain)
		VALUES ($1, $2, 'https://dev.example', 'client', $3)
		ON CONFLICT (id) DO NOTHING`

	for _, tenant := range []struct{ id, name, domain string }{
		{tenantA, "Northwind Mutual", "northwind-mutual.example"},
		{tenantB, "Pacific Grid Utilities", "pacific-grid.example"},
	} {
		if _, err := conn.Exec(ctx, insert, tenant.id, tenant.name, tenant.domain); err != nil {
			t.Fatalf("seeding tenant %s: %v", tenant.name, err)
		}
	}
}

func ensureApplicationRole(t *testing.T, ctx context.Context, conn *pgx.Conn, adminURL string) string {
	t.Helper()

	// The role is created by 0002_grants.sql. Confirm the attributes rather than assume
	// them: a superuser here would make every assertion below pass without consulting a
	// single policy.
	var bypasses bool
	err := conn.QueryRow(ctx,
		`SELECT rolsuper OR rolbypassrls FROM pg_roles WHERE rolname = 'aperture_app'`,
	).Scan(&bypasses)
	if err != nil {
		t.Fatalf("reading aperture_app attributes: %v", err)
	}
	if bypasses {
		t.Fatal("aperture_app can bypass row security; every isolation assertion would be meaningless")
	}

	config, err := pgx.ParseConfig(adminURL)
	if err != nil {
		t.Fatalf("parsing database url: %v", err)
	}

	return "postgres://aperture_app:local-development-only@" +
		config.Host + ":" + itoa(int(config.Port)) + "/" + config.Database + "?sslmode=disable"
}

func itoa(value int) string {
	if value == 0 {
		return "0"
	}
	digits := ""
	for value > 0 {
		digits = string(rune('0'+value%10)) + digits
		value /= 10
	}
	return digits
}

func scoped(tenantID string) context.Context {
	return tenancy.WithPrincipal(context.Background(), tenancy.Principal{
		TenantID: tenantID,
		UserID:   "user-1",
		Roles:    []string{"inspector"},
	})
}

func operation(id, entityID string, base int64, field string) syncapi.Operation {
	return syncapi.Operation{
		OperationID: id,
		EntityType:  "finding",
		EntityID:    entityID,
		Kind:        syncapi.KindUpdate,
		DirtyFields: []string{field},
		BaseVersion: base,
		HLC:         "2026-09-10T00:26:40.123Z-0000-devA",
	}
}

func entityFor(op syncapi.Operation, version int64) *syncapi.Entity {
	return &syncapi.Entity{
		EntityType:    op.EntityType,
		EntityID:      op.EntityID,
		Version:       version,
		HLC:           op.HLC,
		Fields:        map[string]any{op.DirtyFields[0]: "value"},
		FieldVersions: map[string]int64{op.DirtyFields[0]: version},
	}
}

func TestEntityRoundTrips(t *testing.T) {
	store, closeStore := newTestStore(t)
	defer closeStore()

	ctx := scoped(tenantA)
	op := operation("op-1", "f-1", 0, "note")

	if err := store.ApplyOperation(ctx, op, entityFor(op, 1)); err != nil {
		t.Fatalf("applying: %v", err)
	}

	entity, err := store.Entity(ctx, "finding", "f-1")
	if err != nil {
		t.Fatalf("reading: %v", err)
	}
	if entity.Version != 1 || entity.Fields["note"] != "value" {
		t.Fatalf("unexpected entity: %+v", entity)
	}
}

func TestTenantCannotReadAnotherTenantsEntity(t *testing.T) {
	store, closeStore := newTestStore(t)
	defer closeStore()

	op := operation("op-1", "shared-id", 0, "note")
	if err := store.ApplyOperation(scoped(tenantA), op, entityFor(op, 1)); err != nil {
		t.Fatalf("applying as tenant A: %v", err)
	}

	// The same entity identifier, a different tenant. It must look absent rather than
	// forbidden: reporting "exists but not yours" confirms the existence of data the
	// caller cannot see.
	_, err := store.Entity(scoped(tenantB), "finding", "shared-id")
	if err == nil {
		t.Fatal("tenant B read tenant A's entity")
	}
	if err != syncapi.ErrEntityNotFound {
		t.Fatalf("expected ErrEntityNotFound, got %v", err)
	}
}

func TestChangeLogIsScopedToTheTenant(t *testing.T) {
	store, closeStore := newTestStore(t)
	defer closeStore()

	for i, id := range []string{"f-a1", "f-a2", "f-a3"} {
		op := operation("a-"+id, id, 0, "note")
		if err := store.ApplyOperation(scoped(tenantA), op, entityFor(op, int64(i+1))); err != nil {
			t.Fatalf("applying as tenant A: %v", err)
		}
	}

	op := operation("b-1", "f-b1", 0, "note")
	if err := store.ApplyOperation(scoped(tenantB), op, entityFor(op, 1)); err != nil {
		t.Fatalf("applying as tenant B: %v", err)
	}

	changes, _, _, err := store.Changes(scoped(tenantB), "", 100)
	if err != nil {
		t.Fatalf("reading changes: %v", err)
	}

	// Asserted on the identifiers as well as the count. A filter that happens to return
	// the right number of rows is not the same as one that returns the right rows.
	if len(changes) != 1 {
		t.Fatalf("tenant B saw %d changes, expected 1", len(changes))
	}
	if changes[0].EntityID != "f-b1" {
		t.Fatalf("tenant B saw entity %q, which is not its own", changes[0].EntityID)
	}
}

func TestUnscopedContextIsRefused(t *testing.T) {
	store, closeStore := newTestStore(t)
	defer closeStore()

	// The failure that could cross a tenant boundary. It must be loud rather than
	// returning an empty result that reads as missing data.
	if _, err := store.Entity(context.Background(), "finding", "f-1"); err == nil {
		t.Fatal("an unscoped read succeeded")
	}
}

func TestIdempotencyIsScopedToTheTenant(t *testing.T) {
	store, closeStore := newTestStore(t)
	defer closeStore()

	result := syncapi.Result{OperationID: "shared-key", Status: syncapi.StatusApplied, ServerVersion: 1}
	if err := store.StoreResult(scoped(tenantA), "shared-key", result); err != nil {
		t.Fatalf("storing: %v", err)
	}

	// A globally keyed table would return tenant A's stored response to tenant B, which is
	// both a correctness failure and a cross-tenant disclosure.
	if _, found, err := store.ResultForKey(scoped(tenantB), "shared-key"); err != nil {
		t.Fatalf("reading: %v", err)
	} else if found {
		t.Fatal("tenant B received tenant A's stored result")
	}

	if _, found, err := store.ResultForKey(scoped(tenantA), "shared-key"); err != nil {
		t.Fatalf("reading: %v", err)
	} else if !found {
		t.Fatal("tenant A lost its own stored result")
	}
}

func TestStoredResultIsNotReEvaluatedOnRetry(t *testing.T) {
	store, closeStore := newTestStore(t)
	defer closeStore()

	ctx := scoped(tenantA)
	first := syncapi.Result{OperationID: "op-1", Status: syncapi.StatusConflict, ServerVersion: 3}
	second := syncapi.Result{OperationID: "op-1", Status: syncapi.StatusApplied, ServerVersion: 9}

	if err := store.StoreResult(ctx, "op-1", first); err != nil {
		t.Fatalf("storing first: %v", err)
	}
	if err := store.StoreResult(ctx, "op-1", second); err != nil {
		t.Fatalf("storing second: %v", err)
	}

	stored, found, err := store.ResultForKey(ctx, "op-1")
	if err != nil || !found {
		t.Fatalf("reading: %v, found=%v", err, found)
	}

	// The first answer is the one the client must keep receiving. Re-evaluating on a retry
	// lets the two sides disagree about what was decided.
	if stored.Result.Status != syncapi.StatusConflict || stored.Result.ServerVersion != 3 {
		t.Fatalf("stored result was overwritten: %+v", stored.Result)
	}
}

func TestCursorPagesInOrder(t *testing.T) {
	store, closeStore := newTestStore(t)
	defer closeStore()

	ctx := scoped(tenantA)
	for i := 1; i <= 5; i++ {
		id := "f-" + itoa(i)
		op := operation("op-"+id, id, 0, "note")
		if err := store.ApplyOperation(ctx, op, entityFor(op, 1)); err != nil {
			t.Fatalf("applying: %v", err)
		}
	}

	first, cursor, hasMore, err := store.Changes(ctx, "", 2)
	if err != nil {
		t.Fatalf("first page: %v", err)
	}
	if len(first) != 2 || !hasMore {
		t.Fatalf("unexpected first page: %d changes, hasMore=%v", len(first), hasMore)
	}

	second, _, _, err := store.Changes(ctx, cursor, 2)
	if err != nil {
		t.Fatalf("second page: %v", err)
	}
	if len(second) != 2 {
		t.Fatalf("unexpected second page: %d", len(second))
	}
	if second[0].EntityID == first[0].EntityID {
		t.Fatal("the cursor did not advance")
	}
}
