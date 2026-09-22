package httpapi

import (
	"context"
	"encoding/json"
	"net/http"

	"github.com/talif/aperture/backend/internal/obs"
)

// writeJSON serializes a response body.
//
// Takes a context so the encode-failure log line carries the request's correlation
// identifier. The previous version passed nil, which is both a staticcheck finding and a
// practical one: the log line it produced was the only record of a failure that the caller
// can never be told about, and it arrived with nothing to join it to a request.
func writeJSON(ctx context.Context, writer http.ResponseWriter, status int, body any) {
	writer.Header().Set("Content-Type", "application/json")
	writer.WriteHeader(status)

	if body == nil {
		return
	}
	if err := json.NewEncoder(writer).Encode(body); err != nil {
		// The status line is already sent, so there is nothing to report to the caller.
		// Logged rather than swallowed, because a serialization failure here means a
		// response shape changed in a way that nothing else caught.
		obs.Logger(ctx).Error("encoding response", "error", err.Error())
	}
}

// writeError emits the uniform error envelope.
//
// Every failure in this service uses this shape. A client that must branch on response
// format to discover what went wrong will eventually branch wrongly.
func writeError(writer http.ResponseWriter, request *http.Request, status int, code, message string) {
	writeErrorWithDetails(writer, request, status, code, message, nil)
}

// writeErrorWithDetails emits the envelope with structured detail.
//
// The request is required rather than optional. An optional one meant falling back to a
// fresh root context, which detaches the log line from the request that produced it and
// discards the correlation identifier that makes it traceable. Every caller is a handler
// or middleware, so there is always a request to inherit from.
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

	envelope["correlation_id"] = obs.CorrelationID(request.Context())

	if details != nil {
		envelope["details"] = details
	}

	writeJSON(request.Context(), writer, status, map[string]any{"error": envelope})
}
