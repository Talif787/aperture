// Package syncapi implements the change-exchange protocol between devices and the service.
//
// The wire shapes live here rather than in the HTTP layer because they are the contract.
// A handler is an adapter that can be replaced; the field names and semantics below are
// promises to every deployed client, including ones running a build from four months ago
// that the user has not updated because the app works fine offline.
package syncapi

import "time"

// PullRequest asks for changes after a cursor.
type PullRequest struct {
	// Opaque to the client. An opaque cursor can change representation without a protocol
	// version bump; a client that parses a timestamp cursor will break the first time the
	// server needs to encode anything else in it.
	Cursor string `json:"cursor,omitempty"`
	Limit  int    `json:"limit,omitempty"`
}

// PullResponse carries a page of changes and the cursor to resume from.
type PullResponse struct {
	Changes    []Change `json:"changes"`
	NextCursor string   `json:"next_cursor"`

	// HasMore is explicit rather than inferred from a short page. Inferring it makes an
	// exactly-page-sized final batch indistinguishable from a full one, and the client
	// either stops early or makes a pointless extra round trip on a metered connection.
	HasMore bool `json:"has_more"`
}

// Change is one server-side mutation a device has not seen.
type Change struct {
	EntityType    string    `json:"entity_type"`
	EntityID      string    `json:"entity_id"`
	ServerVersion int64     `json:"server_version"`
	HLC           string    `json:"hlc"`
	ChangedFields []string  `json:"changed_fields"`
	IsDeletion    bool      `json:"is_deletion"`
	OccurredAt    time.Time `json:"occurred_at"`
}

// PushRequest carries a batch of device-originated operations.
type PushRequest struct {
	Operations []Operation `json:"operations"`
}

// Operation is one intent to change server state.
type Operation struct {
	// OperationID doubles as the idempotency key. Minted on the device when the intent is
	// recorded, so a retry after an unknown outcome carries the same value and the server
	// replays its stored response rather than applying the effect twice.
	OperationID string `json:"operation_id"`

	EntityType string `json:"entity_type"`
	EntityID   string `json:"entity_id"`
	Kind       string `json:"kind"`

	// DirtyFields is what makes field-level conflict detection possible. Without it the
	// server can only compare versions, and any concurrent edit becomes a whole-entity
	// conflict that clobbers a reviewer's change to a field the inspector never touched.
	DirtyFields []string `json:"dirty_fields"`

	// BaseVersion is the server version this edit was derived from. A mismatch is how
	// concurrency is detected at all.
	BaseVersion int64 `json:"base_version"`

	HLC     string          `json:"hlc"`
	Payload map[string]any  `json:"payload,omitempty"`
}

// PushResponse reports the outcome of each operation, in request order.
type PushResponse struct {
	Results []Result `json:"results"`
}

// Result is what the server made of one operation.
type Result struct {
	OperationID string `json:"operation_id"`

	// Status is one of: applied, replayed, conflict, rejected.
	//
	// `replayed` is distinct from `applied` deliberately. Collapsing them would hide client
	// retry storms, which is exactly the signal an operator needs when a fleet reconnects
	// at shift end and something is going wrong.
	Status string `json:"status"`

	ServerVersion     int64    `json:"server_version,omitempty"`
	ConflictingFields []string `json:"conflicting_fields,omitempty"`
	Code              string   `json:"code,omitempty"`
	Retryable         bool     `json:"retryable,omitempty"`
}

// Result statuses.
const (
	StatusApplied  = "applied"
	StatusReplayed = "replayed"
	StatusConflict = "conflict"
	StatusRejected = "rejected"
)

// Operation kinds the service accepts.
const (
	KindCreate = "create"
	KindUpdate = "update"
	KindDelete = "delete"
)

// MaxOperationsPerPush bounds a batch.
//
// A device dark for three days arrives with hundreds of operations. Accepting them as one
// payload means a single timeout discards all of that progress, and the retry is just as
// likely to time out. Bounded batches make progress monotonic.
const MaxOperationsPerPush = 500

// MaxChangesPerPull bounds a page for the same reason, in the other direction.
const MaxChangesPerPull = 500

// DefaultChangesPerPull is used when a client does not ask.
const DefaultChangesPerPull = 200
