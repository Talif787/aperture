package syncapi

import (
	"context"
	"errors"
	"sync"
	"time"
)

// Errors the service distinguishes.
var (
	ErrEntityNotFound = errors.New("syncapi: entity not found")
	ErrInvalidCursor  = errors.New("syncapi: cursor is not valid")
)

// Entity is the server's authoritative record.
type Entity struct {
	TenantID   string
	EntityType string
	EntityID   string
	Version    int64
	HLC        string
	Fields     map[string]any

	// FieldVersions records which server version last touched each field. This is what
	// allows a conflict to be reported per field rather than per entity, and it is why two
	// actors editing different fields of one record never produce a prompt.
	FieldVersions map[string]int64

	DeletedAt *time.Time
	UpdatedAt time.Time
}

// StoredResult is a cached response for an idempotency key.
type StoredResult struct {
	Result    Result
	CreatedAt time.Time
}

// Store is everything the sync service needs from persistence.
//
// An interface rather than a concrete type so the service logic, which is where conflict
// detection and idempotency live, can be tested exhaustively without a database. The
// PostgreSQL implementation arrives in the next phase and must satisfy exactly this.
type Store interface {
	// Entity reads one record within the caller's tenant.
	Entity(ctx context.Context, entityType, entityID string) (*Entity, error)

	// ApplyOperation writes an entity and appends to the change log atomically.
	//
	// Atomicity is the requirement, not an implementation detail: a record written without
	// its change-log row is invisible to every other device forever, and no later
	// reconciliation can discover it because nothing records that it is missing.
	ApplyOperation(ctx context.Context, op Operation, next *Entity) error

	// Changes returns entries after a cursor, oldest first.
	Changes(ctx context.Context, cursor string, limit int) ([]Change, string, bool, error)

	// ResultForKey returns a previously stored response, if this key has been seen.
	ResultForKey(ctx context.Context, key string) (*StoredResult, bool, error)

	// StoreResult caches a response against its idempotency key.
	StoreResult(ctx context.Context, key string, result Result) error
}

// changeRecord pairs a change with the scope and sequence the store needs but the wire
// format does not carry.
//
// A global sequence with a tenant filter, rather than a per-tenant counter, because that is
// what the PostgreSQL implementation will do: one `bigserial` and a `WHERE tenant_id = $1`
// that row-level security enforces anyway. Modelling it differently here would mean the
// cursor semantics changed when the real store arrived, and cursor bugs are the kind that
// silently skip a client's changes.
type changeRecord struct {
	sequence int64
	tenantID string
	change   Change
}

// InMemoryStore is a working implementation, used by tests and by local development.
//
// Not a mock. It enforces the same version and tenancy rules the real store does, so a test
// against it is a test of behavior rather than of which methods were called.
type InMemoryStore struct {
	mu sync.RWMutex

	entities map[string]*Entity
	changes  []changeRecord
	results  map[string]StoredResult

	// Sequence is the cursor source. A monotonic integer rather than a timestamp: two
	// changes can share a millisecond, and a timestamp cursor would either skip one or
	// return it twice forever.
	sequence int64

	now func() time.Time
}

// NewInMemoryStore builds an empty store.
func NewInMemoryStore(now func() time.Time) *InMemoryStore {
	if now == nil {
		now = time.Now
	}
	return &InMemoryStore{
		entities: make(map[string]*Entity),
		results:  make(map[string]StoredResult),
		now:      now,
	}
}

func entityKey(tenantID, entityType, entityID string) string {
	return tenantID + "|" + entityType + "|" + entityID
}

// Entity implements Store.
func (s *InMemoryStore) Entity(ctx context.Context, entityType, entityID string) (*Entity, error) {
	tenantID, err := tenantFrom(ctx)
	if err != nil {
		return nil, err
	}

	s.mu.RLock()
	defer s.mu.RUnlock()

	entity, ok := s.entities[entityKey(tenantID, entityType, entityID)]
	if !ok {
		return nil, ErrEntityNotFound
	}

	clone := *entity
	clone.Fields = copyFields(entity.Fields)
	clone.FieldVersions = copyVersions(entity.FieldVersions)
	return &clone, nil
}

// ApplyOperation implements Store.
func (s *InMemoryStore) ApplyOperation(ctx context.Context, op Operation, next *Entity) error {
	tenantID, err := tenantFrom(ctx)
	if err != nil {
		return err
	}

	s.mu.Lock()
	defer s.mu.Unlock()

	next.TenantID = tenantID
	next.UpdatedAt = s.now()
	s.entities[entityKey(tenantID, op.EntityType, op.EntityID)] = next

	s.sequence++
	s.changes = append(s.changes, changeRecord{
		sequence: s.sequence,
		tenantID: tenantID,
		change: Change{
			EntityType:    op.EntityType,
			EntityID:      op.EntityID,
			ServerVersion: next.Version,
			HLC:           op.HLC,
			ChangedFields: append([]string(nil), op.DirtyFields...),
			IsDeletion:    op.Kind == KindDelete,
			OccurredAt:    next.UpdatedAt,
		},
	})

	return nil
}

// Changes implements Store.
//
// Scoped to the caller's tenant. The earlier version read the tenant, confirmed it was
// present, and then returned the whole change log: every device would have received every
// other customer's inspection activity on its next sync. That is the highest-severity
// failure this system can produce, and nothing about the code looked wrong, because the
// tenant lookup was right there at the top of the function.
func (s *InMemoryStore) Changes(
	ctx context.Context, cursor string, limit int,
) ([]Change, string, bool, error) {
	tenantID, err := tenantFrom(ctx)
	if err != nil {
		return nil, "", false, err
	}

	after, err := decodeCursor(cursor)
	if err != nil {
		return nil, "", false, err
	}

	s.mu.RLock()
	defer s.mu.RUnlock()

	page := make([]Change, 0, limit)
	last := after

	for _, record := range s.changes {
		if record.tenantID != tenantID || record.sequence <= after {
			continue
		}

		if len(page) == limit {
			// One more match exists beyond the page. Reported explicitly rather than
			// inferred from a full page, so an exactly-page-sized final batch is not
			// mistaken for a full one.
			return page, encodeCursor(last), true, nil
		}

		page = append(page, record.change)
		last = record.sequence
	}

	// A cursor beyond anything in the log simply matches nothing, which is the right
	// answer after a restore from backup: the device recovers on the next change rather
	// than being stuck on an error it cannot act on.
	return page, encodeCursor(last), false, nil
}

// ResultForKey implements Store.
func (s *InMemoryStore) ResultForKey(ctx context.Context, key string) (*StoredResult, bool, error) {
	tenantID, err := tenantFrom(ctx)
	if err != nil {
		return nil, false, err
	}

	s.mu.RLock()
	defer s.mu.RUnlock()

	// Scoped to the tenant. A globally keyed idempotency table would let one tenant's
	// operation identifier collide with another's, and the second caller would receive the
	// first caller's response.
	stored, ok := s.results[tenantID+"|"+key]
	if !ok {
		return nil, false, nil
	}
	return &stored, true, nil
}

// StoreResult implements Store.
func (s *InMemoryStore) StoreResult(ctx context.Context, key string, result Result) error {
	tenantID, err := tenantFrom(ctx)
	if err != nil {
		return err
	}

	s.mu.Lock()
	defer s.mu.Unlock()

	s.results[tenantID+"|"+key] = StoredResult{Result: result, CreatedAt: s.now()}
	return nil
}

func copyFields(source map[string]any) map[string]any {
	target := make(map[string]any, len(source))
	for key, value := range source {
		target[key] = value
	}
	return target
}

func copyVersions(source map[string]int64) map[string]int64 {
	target := make(map[string]int64, len(source))
	for key, value := range source {
		target[key] = value
	}
	return target
}
