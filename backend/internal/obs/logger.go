// Package obs provides the observability primitives every other package depends on.
//
// Logging is structured from the first line rather than retrofitted, and redaction is a
// property of this package rather than a rule each call site is trusted to remember.
// Relying on discipline at the call site is a policy that fails silently and exactly once,
// and the failure is customer content in a log aggregator.
package obs

import (
	"context"
	"log/slog"
	"os"
	"strings"
)

type contextKey string

const correlationIDKey contextKey = "correlation_id"

// NewLogger builds the process logger. JSON always, including locally: a format that
// differs between development and production means the parsing is only exercised in
// production.
func NewLogger(level string, environment string) *slog.Logger {
	handler := slog.NewJSONHandler(os.Stdout, &slog.HandlerOptions{
		Level:       parseLevel(level),
		ReplaceAttr: redact,
	})

	return slog.New(handler).With(
		slog.String("service", "aperture"),
		slog.String("environment", environment),
	)
}

func parseLevel(level string) slog.Level {
	switch strings.ToLower(level) {
	case "debug":
		return slog.LevelDebug
	case "warn", "warning":
		return slog.LevelWarn
	case "error":
		return slog.LevelError
	default:
		return slog.LevelInfo
	}
}

// deniedKeys never reach a log sink regardless of which package logs them. The list is
// deliberately broader than the fields that exist today, because the cost of a false
// positive is a redacted debug line and the cost of a false negative is a privacy
// incident.
var deniedKeys = map[string]struct{}{
	"token":         {},
	"access_token":  {},
	"refresh_token": {},
	"authorization": {},
	"password":      {},
	"secret":        {},
	"api_key":       {},
	"email":         {},
	"address":       {},
	"note":          {},
	"notes":         {},
	"form_data":     {},
	"payload":       {},
	"latitude":      {},
	"longitude":     {},
}

func redact(_ []string, attr slog.Attr) slog.Attr {
	if _, denied := deniedKeys[strings.ToLower(attr.Key)]; denied {
		return slog.String(attr.Key, "[redacted]")
	}
	return attr
}

// WithCorrelationID stores the request correlation identifier on the context so that every
// log line and span emitted while handling the request can be joined to the device that
// originated it.
func WithCorrelationID(ctx context.Context, id string) context.Context {
	return context.WithValue(ctx, correlationIDKey, id)
}

// CorrelationID returns the identifier stored by WithCorrelationID, or the empty string.
func CorrelationID(ctx context.Context) string {
	if value, ok := ctx.Value(correlationIDKey).(string); ok {
		return value
	}
	return ""
}

// FromContext returns a logger already annotated with the request correlation identifier.
func FromContext(ctx context.Context, base *slog.Logger) *slog.Logger {
	if id := CorrelationID(ctx); id != "" {
		return base.With(slog.String("correlation_id", id))
	}
	return base
}
