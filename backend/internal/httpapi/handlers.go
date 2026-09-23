package httpapi

import (
	"encoding/json"
	"errors"
	"net/http"
	"strconv"

	"github.com/talif/aperture/backend/internal/metrics"
	"github.com/talif/aperture/backend/internal/obs"
	"github.com/talif/aperture/backend/internal/syncapi"
	"github.com/talif/aperture/backend/internal/tenancy"
)

// MaxRequestBytes bounds a request body.
//
// A push batch of five hundred operations with payloads is large but bounded; anything
// beyond this is either a bug or an attempt to exhaust memory, and both are handled the
// same way.
const MaxRequestBytes = 8 << 20

// Handlers serves the sync endpoints.
type Handlers struct {
	Sync *syncapi.Service

	// Optional. Nil is valid and records nothing, so a test does not have to construct a
	// registry to exercise a handler.
	Metrics *metrics.Recorder
}

// Register mounts the routes on a mux.
func (h Handlers) Register(mux *http.ServeMux, authenticator Authenticator, minimumClient string) {
	protected := func(handler http.HandlerFunc) http.Handler {
		// Order matters. The version gate runs before authentication so an unsupported
		// client gets a specific, actionable answer rather than a token error that sends
		// the user to reinstall the app.
		return MinimumClientVersion(minimumClient)(authenticator.Middleware(handler))
	}

	mux.Handle("GET /v1/sync/changes", protected(h.pullChanges))
	mux.Handle("POST /v1/sync/deltas", protected(h.pushDeltas))
	mux.Handle("GET /v1/me", protected(h.whoami))
}

func (h Handlers) pullChanges(writer http.ResponseWriter, request *http.Request) {
	limit := 0
	if raw := request.URL.Query().Get("limit"); raw != "" {
		parsed, err := strconv.Atoi(raw)
		if err != nil || parsed <= 0 {
			writeError(writer, request, http.StatusBadRequest, "VALIDATION_FAILED",
				"limit must be a positive integer.")
			return
		}
		limit = parsed
	}

	response, err := h.Sync.Pull(request.Context(), syncapi.PullRequest{
		Cursor: request.URL.Query().Get("cursor"),
		Limit:  limit,
	})

	switch {
	case errors.Is(err, syncapi.ErrInvalidCursor):
		writeError(writer, request, http.StatusBadRequest, "VALIDATION_FAILED",
			"The cursor is not valid. Start from the beginning by omitting it.")
		return
	case errors.Is(err, tenancy.ErrNoTenantInContext):
		// Unreachable behind the authentication middleware, and handled anyway: an
		// unscoped request reaching the store is the one failure that could cross a tenant
		// boundary, so it fails loudly rather than returning an empty page.
		writeError(writer, request, http.StatusUnauthorized, "UNAUTHENTICATED",
			"The request is not scoped to a tenant.")
		return
	case err != nil:
		writeInternalError(writer, request, err)
		return
	}

	if h.Metrics != nil {
		h.Metrics.ChangesPulled(len(response.Changes))
	}

	writeJSON(request.Context(), writer, http.StatusOK, response)
}

func (h Handlers) pushDeltas(writer http.ResponseWriter, request *http.Request) {
	body := http.MaxBytesReader(writer, request.Body, MaxRequestBytes)

	var payload syncapi.PushRequest
	decoder := json.NewDecoder(body)

	// Unknown fields are rejected rather than ignored. A client sending a field the server
	// does not understand believes something is being recorded that is not, and silently
	// discarding it is how a protocol drifts without anyone noticing.
	decoder.DisallowUnknownFields()

	if err := decoder.Decode(&payload); err != nil {
		writeError(writer, request, http.StatusBadRequest, "VALIDATION_FAILED",
			"The request body could not be decoded.")
		return
	}

	if len(payload.Operations) == 0 {
		writeError(writer, request, http.StatusBadRequest, "VALIDATION_FAILED",
			"At least one operation is required.")
		return
	}

	response, err := h.Sync.Push(request.Context(), payload)

	switch {
	case errors.Is(err, syncapi.ErrBatchTooLarge):
		writeErrorWithDetails(writer, request, http.StatusBadRequest, "VALIDATION_FAILED",
			"Too many operations in one batch.",
			map[string]any{"maximum_operations": syncapi.MaxOperationsPerPush})
		return
	case errors.Is(err, tenancy.ErrNoTenantInContext):
		writeError(writer, request, http.StatusUnauthorized, "UNAUTHENTICATED",
			"The request is not scoped to a tenant.")
		return
	case err != nil:
		writeInternalError(writer, request, err)
		return
	}

	h.recordOutcomes(response)

	// 200 rather than 207. Every operation reports its own status in the body, and a
	// multi-status code would make clients branch on the transport layer for something the
	// payload already says precisely.
	writeJSON(request.Context(), writer, http.StatusOK, response)
}

// whoami reflects the verified principal.
//
// Exists for operators and for this project's runbook: it is the shortest way to prove
// that a token resolves to the tenant and roles you expect, before spending time debugging
// a sync call that was never going to be scoped correctly.
func (h Handlers) whoami(writer http.ResponseWriter, request *http.Request) {
	principal, err := tenancy.PrincipalFrom(request.Context())
	if err != nil {
		writeError(writer, request, http.StatusUnauthorized, "UNAUTHENTICATED",
			"The request is not scoped to a tenant.")
		return
	}

	writeJSON(request.Context(), writer, http.StatusOK, map[string]any{
		"tenant_id": principal.TenantID,
		"user_id":   principal.UserID,
		"roles":     principal.Roles,
	})
}

// recordOutcomes counts what the server decided, which HTTP status cannot express.
//
// Every push returns 200 whatever happened inside it, because each operation carries its
// own status. Without this, a fleet whose operations are all conflicting looks identical
// on a dashboard to one where everything applies cleanly.
func (h Handlers) recordOutcomes(response *syncapi.PushResponse) {
	if h.Metrics == nil {
		return
	}

	for _, result := range response.Results {
		h.Metrics.SyncOperationApplied(result.Status)

		for _, field := range result.ConflictingFields {
			h.Metrics.SyncConflictDetected(field)
		}
	}
}

func writeInternalError(writer http.ResponseWriter, request *http.Request, err error) {
	// The detail goes to the log with the correlation identifier; the caller gets a code.
	// An internal message in a response is an information leak and is unreadable to the
	// person holding the phone.
	obs.Logger(request.Context()).Error("request failed", "error", err.Error())
	writeError(writer, request, http.StatusInternalServerError, "INTERNAL",
		"The request could not be completed.")
}
