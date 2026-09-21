package httpapi

import (
	"encoding/json"
	"net/http"

	"github.com/talif/aperture/backend/internal/obs"
)

// writeJSON serializes a response body.
func writeJSON(writer http.ResponseWriter, status int, body any) {
	writer.Header().Set("Content-Type", "application/json")
	writer.WriteHeader(status)

	if body == nil {
		return
	}
	if err := json.NewEncoder(writer).Encode(body); err != nil {
		// The status line is already sent, so there is nothing to report to the caller.
		// Logged rather than swallowed, because a serialization failure here means a
		// response shape changed in a way that nothing else caught.
		obs.Logger(nil).Error("encoding response", "error", err.Error())
	}
}

// writeError emits the uniform error envelope.
//
// Every failure in this service uses this shape. A client that must branch on response
// format to discover what went wrong will eventually branch wrongly.
func writeError(writer http.ResponseWriter, request *http.Request, status int, code, message string) {
	writeErrorWithDetails(writer, request, status, code, message, nil)
}

func writeErrorWithDetails(
	writer http.ResponseWriter,
	request *http.Request,
	status int,
	code string,
	message string,
	details map[string]any,
) {
	envelope := map[string]any{
		"code":        code,
		"http_status": status,
		// The message is for engineers and logs. Clients map `code` to a localized string
		// and never display this text, which is why it can name internals safely.
		"message":   message,
		"retryable": status == http.StatusTooManyRequests || status >= http.StatusInternalServerError,
	}

	if request != nil {
		envelope["correlation_id"] = obs.CorrelationID(request.Context())
	}
	if details != nil {
		envelope["details"] = details
	}

	writeJSON(writer, status, map[string]any{"error": envelope})
}
