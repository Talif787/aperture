// Package httpx contains the HTTP middleware chain shared by every route.
package httpx

import (
	"crypto/rand"
	"encoding/hex"
	"log/slog"
	"net/http"
	"time"

	"github.com/talif/aperture/backend/internal/obs"
)

// CorrelationIDHeader carries an identifier generated on the device.
//
// The device generates it, not the server, and that direction matters: it is what makes a
// single field session traceable from the moment the shutter is pressed through to the
// database commit. A server-generated identifier can only ever describe the server's half.
const CorrelationIDHeader = "X-Correlation-Id"

// Middleware is a standard decorator over http.Handler.
type Middleware func(http.Handler) http.Handler

// Chain applies middleware in the order given, so the first argument is outermost.
func Chain(handler http.Handler, middleware ...Middleware) http.Handler {
	for index := len(middleware) - 1; index >= 0; index-- {
		handler = middleware[index](handler)
	}
	return handler
}

// WithCorrelationID adopts the client's identifier or mints one when absent, and echoes it
// back so a client can record what the server used.
func WithCorrelationID(next http.Handler) http.Handler {
	return http.HandlerFunc(func(writer http.ResponseWriter, request *http.Request) {
		id := request.Header.Get(CorrelationIDHeader)
		if id == "" || len(id) > 64 {
			id = newID()
		}

		writer.Header().Set(CorrelationIDHeader, id)
		next.ServeHTTP(writer, request.WithContext(obs.WithCorrelationID(request.Context(), id)))
	})
}

// WithAccessLog records one structured line per request.
//
// Method, path, status, and duration only. Never a body: sync request bodies contain form
// values and free text by definition, and an access log is the easiest place for that
// content to escape unnoticed.
func WithAccessLog(logger *slog.Logger) Middleware {
	return func(next http.Handler) http.Handler {
		return http.HandlerFunc(func(writer http.ResponseWriter, request *http.Request) {
			started := time.Now()
			recorder := &statusRecorder{ResponseWriter: writer, status: http.StatusOK}

			next.ServeHTTP(recorder, request)

			obs.FromContext(request.Context(), logger).Info("request",
				slog.String("method", request.Method),
				slog.String("path", request.URL.Path),
				slog.Int("status", recorder.status),
				slog.Int64("duration_ms", time.Since(started).Milliseconds()),
			)
		})
	}
}

// WithRecovery converts a panic into a 500 rather than a dropped connection, and logs it
// with the correlation identifier so the failure can be traced back to a device.
func WithRecovery(logger *slog.Logger) Middleware {
	return func(next http.Handler) http.Handler {
		return http.HandlerFunc(func(writer http.ResponseWriter, request *http.Request) {
			defer func() {
				if recovered := recover(); recovered != nil {
					obs.FromContext(request.Context(), logger).Error("panic recovered",
						slog.Any("panic", recovered),
						slog.String("path", request.URL.Path),
					)
					http.Error(writer, `{"error":{"code":"INTERNAL","http_status":500}}`,
						http.StatusInternalServerError)
				}
			}()

			next.ServeHTTP(writer, request)
		})
	}
}

// WithMaxBodySize rejects oversized requests before they are read into memory.
func WithMaxBodySize(limit int64) Middleware {
	return func(next http.Handler) http.Handler {
		return http.HandlerFunc(func(writer http.ResponseWriter, request *http.Request) {
			request.Body = http.MaxBytesReader(writer, request.Body, limit)
			next.ServeHTTP(writer, request)
		})
	}
}

type statusRecorder struct {
	http.ResponseWriter
	status int
}

// WriteHeader records the status before delegating, so the access log can report it
// without every handler having to cooperate.
func (recorder *statusRecorder) WriteHeader(code int) {
	recorder.status = code
	recorder.ResponseWriter.WriteHeader(code)
}

func newID() string {
	buffer := make([]byte, 16)
	if _, err := rand.Read(buffer); err != nil {
		// A failure of the system CSPRNG is not recoverable in a useful way here, and a
		// timestamp fallback would produce colliding identifiers under load. Returning an
		// empty identifier is honest: the trace is simply not joined for this request.
		return ""
	}
	return hex.EncodeToString(buffer)
}
