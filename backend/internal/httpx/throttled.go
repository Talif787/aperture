package httpx

import (
	"encoding/json"
	"net/http"

	"github.com/talif/aperture/backend/internal/obs"
)

// writeThrottled emits the same error envelope shape every other refusal uses.
//
// The envelope matters more than it looks. A client that has to parse one shape for
// validation failures and another for throttling grows two code paths, and the one it
// exercises least is the one that runs during an incident.
func writeThrottled(writer http.ResponseWriter, request *http.Request, retryAfter int) {
	writer.Header().Set("Content-Type", "application/json")
	writer.WriteHeader(Throttled)

	// The details map is built separately so every entry in the literal below is a single
	// line. A multi-line value inside a literal changes how the formatter groups the
	// alignment, and a block whose shape depends on that is one nobody edits confidently.
	details := map[string]any{"retry_after_seconds": retryAfter}

	// retryable is explicit and true. The sync engine distinguishes a permanent rejection
	// from a transient failure, and a throttle that looked permanent would make a device
	// dead-letter work it should simply resend a moment later.

	body := map[string]any{
		"error": map[string]any{
			"code":           "RATE_LIMITED",
			"message":        "Too many requests for this tenant. Retry after the advertised delay.",
			"correlation_id": obs.CorrelationID(request.Context()),
			"details":        details,
			"retryable":      true,
		},
	}

	if err := json.NewEncoder(writer).Encode(body); err != nil {
		obs.Logger(request.Context()).Error("encoding throttle response", "error", err.Error())
	}
}
