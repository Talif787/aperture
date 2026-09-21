package syncapi

import (
	"context"
	"errors"
	"fmt"
	"strconv"
	"time"

	"github.com/talif/aperture/backend/internal/tenancy"
)

// Service applies the change-exchange protocol.
//
// Deliberately free of HTTP. Conflict detection and idempotency are the parts worth
// testing exhaustively, and coupling them to request parsing would mean every case needed
// a synthetic request to exercise it.
type Service struct {
	store Store
	now   func() time.Time
}

// NewService builds a service over a store.
func NewService(store Store, now func() time.Time) *Service {
	if now == nil {
		now = time.Now
	}
	return &Service{store: store, now: now}
}

// Pull returns changes the device has not seen.
func (s *Service) Pull(ctx context.Context, request PullRequest) (*PullResponse, error) {
	limit := request.Limit
	if limit <= 0 {
		limit = DefaultChangesPerPull
	}
	if limit > MaxChangesPerPull {
		limit = MaxChangesPerPull
	}

	changes, next, hasMore, err := s.store.Changes(ctx, request.Cursor, limit)
	if err != nil {
		return nil, err
	}

	if changes == nil {
		// An empty slice rather than nil, so the field serializes as [] and not null. A
		// client decoding null into a non-optional array is a crash, and it is the kind
		// that only happens on the one device that had nothing to pull.
		changes = []Change{}
	}

	return &PullResponse{Changes: changes, NextCursor: next, HasMore: hasMore}, nil
}

// Push applies a batch of device operations.
//
// Each operation is independent. One rejection does not fail the batch, because a device
// with a single poisoned operation would otherwise be unable to sync anything at all, and
// the user has no way to identify or remove the offending record.
func (s *Service) Push(ctx context.Context, request PushRequest) (*PushResponse, error) {
	if len(request.Operations) > MaxOperationsPerPush {
		return nil, fmt.Errorf("%w: %d operations exceeds the limit of %d",
			ErrBatchTooLarge, len(request.Operations), MaxOperationsPerPush)
	}

	response := &PushResponse{Results: make([]Result, 0, len(request.Operations))}

	for _, operation := range request.Operations {
		result, err := s.apply(ctx, operation)
		if err != nil {
			// An infrastructure failure aborts the batch rather than reporting a rejection
			// the client would treat as permanent. The client retries the whole batch with
			// its keys intact, and the operations that already landed replay.
			return nil, err
		}
		response.Results = append(response.Results, result)
	}

	return response, nil
}

// ErrBatchTooLarge is returned when a push exceeds the batch limit.
var ErrBatchTooLarge = errors.New("syncapi: batch too large")

func (s *Service) apply(ctx context.Context, op Operation) (Result, error) {
	if problem := validate(op); problem != "" {
		return Result{
			OperationID: op.OperationID,
			Status:      StatusRejected,
			Code:        "VALIDATION_FAILED",
			Retryable:   false,
		}, nil
	}

	// Replay check first, before anything is read or written. A retry after an unknown
	// outcome must return the original answer, not a second application, and checking
	// later would leave a window where the effect is applied twice.
	if stored, found, err := s.store.ResultForKey(ctx, op.OperationID); err != nil {
		return Result{}, err
	} else if found {
		replayed := stored.Result
		if replayed.Status == StatusApplied {
			replayed.Status = StatusReplayed
		}
		return replayed, nil
	}

	entity, err := s.store.Entity(ctx, op.EntityType, op.EntityID)
	switch {
	case errors.Is(err, ErrEntityNotFound):
		entity = nil
	case err != nil:
		return Result{}, err
	}

	result, next := s.resolve(op, entity)

	if result.Status == StatusApplied {
		if err := s.store.ApplyOperation(ctx, op, next); err != nil {
			return Result{}, err
		}
	}

	// Conflicts and rejections are stored too. A client that retries after a conflict must
	// receive the same conflict rather than a fresh evaluation against a server that has
	// moved on, or the two sides can disagree about what was decided.
	if err := s.store.StoreResult(ctx, op.OperationID, result); err != nil {
		return Result{}, err
	}

	return result, nil
}

// resolve decides one operation against current server state.
func (s *Service) resolve(op Operation, entity *Entity) (Result, *Entity) {
	if entity == nil {
		if op.BaseVersion != 0 {
			// The device believes it is editing something the server has never seen. The
			// usual cause is a restore onto a different backend, and applying it would
			// silently resurrect a record that was deliberately removed.
			return Result{
				OperationID: op.OperationID,
				Status:      StatusConflict,
				Code:        "ENTITY_MISSING",
			}, nil
		}

		return Result{
				OperationID:   op.OperationID,
				Status:        StatusApplied,
				ServerVersion: 1,
			}, &Entity{
				EntityType:    op.EntityType,
				EntityID:      op.EntityID,
				Version:       1,
				HLC:           op.HLC,
				Fields:        fieldsFrom(op),
				FieldVersions: versionsFor(op.DirtyFields, 1),
			}
	}

	if entity.Version == op.BaseVersion {
		return s.applied(op, entity)
	}

	// A version mismatch alone is not a conflict. Only a field that changed on the server
	// *after* the device's base version, and that the device also changed, is a genuine
	// disagreement. Everything else is ordinary concurrency, and treating it as a conflict
	// would put a resolution prompt in front of an inspector several times a shift.
	conflicting := make([]string, 0)
	for _, field := range op.DirtyFields {
		if entity.FieldVersions[field] > op.BaseVersion {
			conflicting = append(conflicting, field)
		}
	}

	if len(conflicting) == 0 {
		return s.applied(op, entity)
	}

	return Result{
		OperationID:       op.OperationID,
		Status:            StatusConflict,
		ServerVersion:     entity.Version,
		ConflictingFields: conflicting,
	}, nil
}

func (s *Service) applied(op Operation, entity *Entity) (Result, *Entity) {
	next := &Entity{
		EntityType:    op.EntityType,
		EntityID:      op.EntityID,
		Version:       entity.Version + 1,
		HLC:           op.HLC,
		Fields:        copyFields(entity.Fields),
		FieldVersions: copyVersions(entity.FieldVersions),
		DeletedAt:     entity.DeletedAt,
	}

	if op.Kind == KindDelete {
		// Soft delete. A deletion must propagate to replicas that are currently in a crawl
		// space with no signal, and a removed row propagates nothing.
		deletedAt := s.now()
		next.DeletedAt = &deletedAt
	}

	for key, value := range op.Payload {
		next.Fields[key] = value
	}
	for _, field := range op.DirtyFields {
		next.FieldVersions[field] = next.Version
	}

	return Result{
		OperationID:   op.OperationID,
		Status:        StatusApplied,
		ServerVersion: next.Version,
	}, next
}

func validate(op Operation) string {
	switch {
	case op.OperationID == "":
		return "operation_id is required"
	case op.EntityType == "":
		return "entity_type is required"
	case op.EntityID == "":
		return "entity_id is required"
	case op.HLC == "":
		return "hlc is required"
	case op.BaseVersion < 0:
		return "base_version cannot be negative"
	case op.Kind != KindCreate && op.Kind != KindUpdate && op.Kind != KindDelete:
		return "kind must be create, update, or delete"
	case len(op.DirtyFields) == 0 && op.Kind != KindDelete:
		// Without dirty fields the server can only do whole-entity comparison, which
		// clobbers a reviewer's change to a field the inspector never touched.
		return "dirty_fields is required for create and update"
	default:
		return ""
	}
}

func fieldsFrom(op Operation) map[string]any {
	fields := make(map[string]any, len(op.Payload))
	for key, value := range op.Payload {
		fields[key] = value
	}
	return fields
}

func versionsFor(fields []string, version int64) map[string]int64 {
	versions := make(map[string]int64, len(fields))
	for _, field := range fields {
		versions[field] = version
	}
	return versions
}

func encodeCursor(sequence int64) string {
	return strconv.FormatInt(sequence, 10)
}

func decodeCursor(cursor string) (int64, error) {
	if cursor == "" {
		return 0, nil
	}
	value, err := strconv.ParseInt(cursor, 10, 64)
	if err != nil || value < 0 {
		return 0, ErrInvalidCursor
	}
	return value, nil
}

// tenantFrom is the single point where the store learns its scope.
//
// It returns an error rather than an empty string when the context was never scoped,
// because an empty tenant would widen every read to "no filter" and nothing about the code
// would look wrong.
func tenantFrom(ctx context.Context) (string, error) {
	return tenancy.TenantFrom(ctx)
}
