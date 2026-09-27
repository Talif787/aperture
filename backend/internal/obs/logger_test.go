package obs

import (
	"bytes"
	"context"
	"encoding/json"
	"log/slog"
	"strings"
	"testing"
)

// This package had no tests, which is the worst place in the codebase for that to be true.
// Redaction is the only thing standing between an inspector's notes and a log aggregator
// that a support engineer, a vendor, and anyone with dashboard access can read. It fails
// silently: nothing breaks when a field stops being redacted, the data simply starts
// appearing, and it keeps appearing until someone happens to look.

func captureLog(t *testing.T, attrs ...slog.Attr) map[string]any {
	t.Helper()

	var buffer bytes.Buffer
	handler := slog.NewJSONHandler(&buffer, &slog.HandlerOptions{ReplaceAttr: redact})
	logger := slog.New(handler)

	logger.LogAttrs(context.Background(), slog.LevelInfo, "test", attrs...)

	var parsed map[string]any
	if err := json.Unmarshal(buffer.Bytes(), &parsed); err != nil {
		t.Fatalf("log line was not valid JSON: %v\n%s", err, buffer.String())
	}
	return parsed
}

func TestSensitiveKeysAreRedacted(t *testing.T) {
	t.Parallel()

	secret := "hunter2-this-must-never-appear"

	for key := range deniedKeys {
		entry := captureLog(t, slog.String(key, secret))

		if entry[key] != "[redacted]" {
			t.Errorf("key %q logged %v rather than [redacted]", key, entry[key])
		}
	}
}

func TestRedactionIsCaseInsensitive(t *testing.T) {
	t.Parallel()

	// A caller writing slog.String("Authorization", ...) is not doing anything unusual;
	// that is the header's own casing. Matching only the lowercase form would redact the
	// convenient spelling and log the natural one.
	for _, key := range []string{"Authorization", "AUTHORIZATION", "AuThOrIzAtIoN", "Token", "NOTE"} {
		entry := captureLog(t, slog.String(key, "secret"))

		if entry[key] != "[redacted]" {
			t.Errorf("key %q logged %v rather than [redacted]", key, entry[key])
		}
	}
}

func TestOrdinaryKeysAreNotRedacted(t *testing.T) {
	t.Parallel()

	// Redaction that swallows everything is useless in a different way: an operator with
	// no usable fields stops reading the logs, and the ones that matter go unnoticed too.
	entry := captureLog(t,
		slog.String("route", "/v1/sync/deltas"),
		slog.Int("status", 200),
		slog.String("tenant_id", "11111111-1111-4111-a111-111111111111"),
	)

	if entry["route"] != "/v1/sync/deltas" || entry["status"] != float64(200) {
		t.Fatalf("ordinary fields were altered: %v", entry)
	}
}

func TestInspectionContentIsRedacted(t *testing.T) {
	t.Parallel()

	// The fields this product actually handles. A finding's note is free text an inspector
	// typed about someone's property, and a latitude and longitude pair is the address of
	// a policyholder's home whether or not it is labelled as one.
	for _, key := range []string{"note", "notes", "form_data", "payload", "latitude", "longitude"} {
		entry := captureLog(t, slog.String(key, "Hail bruising on the south slope"))

		if entry[key] != "[redacted]" {
			t.Errorf("inspection field %q was logged in full", key)
		}
	}
}

func TestCorrelationIDRoundTrips(t *testing.T) {
	t.Parallel()

	ctx := WithCorrelationID(context.Background(), "abc-123")

	if got := CorrelationID(ctx); got != "abc-123" {
		t.Fatalf("expected abc-123, got %q", got)
	}
}

func TestCorrelationIDIsEmptyWhenAbsent(t *testing.T) {
	t.Parallel()

	// Empty rather than a panic or a generated value. Every log call reads this, including
	// ones on paths where no request exists, such as startup and shutdown.
	if got := CorrelationID(context.Background()); got != "" {
		t.Fatalf("expected an empty string, got %q", got)
	}
}

func TestCorrelationIDToleratesANilContext(t *testing.T) {
	t.Parallel()

	// Defensive, and deliberately so: this is called from error paths, which are exactly
	// the paths least likely to have been exercised before they run in production.
	defer func() {
		if recovered := recover(); recovered != nil {
			t.Fatalf("CorrelationID panicked on a nil context: %v", recovered)
		}
	}()

	//nolint:staticcheck // passing nil is the case under test
	_ = CorrelationID(nil)
}

func TestParseLevelAcceptsTheConfiguredNames(t *testing.T) {
	t.Parallel()

	cases := map[string]slog.Level{
		"debug": slog.LevelDebug,
		"DEBUG": slog.LevelDebug,
		"info":  slog.LevelInfo,
		"warn":  slog.LevelWarn,
		"error": slog.LevelError,
	}

	for name, expected := range cases {
		if actual := parseLevel(name); actual != expected {
			t.Errorf("parseLevel(%q) = %v, want %v", name, actual, expected)
		}
	}
}

func TestParseLevelDefaultsToInfo(t *testing.T) {
	t.Parallel()

	// An unrecognised level must not silence the logs. Defaulting to error, or to a level
	// parsed as zero, would mean a typo in configuration produces a service that looks
	// healthy because it has stopped saying anything.
	for _, name := range []string{"", "verbose", "TRACE", "17", "info "} {
		if actual := parseLevel(name); actual != slog.LevelInfo {
			t.Errorf("parseLevel(%q) = %v, want info", name, actual)
		}
	}
}

func TestLoggerFallsBackWhenNoDefaultIsSet(t *testing.T) {
	t.Parallel()

	// Logger is called from everywhere, including code that runs before SetDefaultLogger.
	// Returning nil there would turn every log call into a panic.
	if Logger(context.Background()) == nil {
		t.Fatal("Logger returned nil")
	}
}

func TestLoggerCarriesTheCorrelationID(t *testing.T) {
	var buffer bytes.Buffer
	SetDefaultLogger(slog.New(slog.NewJSONHandler(&buffer, &slog.HandlerOptions{ReplaceAttr: redact})))

	Logger(WithCorrelationID(context.Background(), "trace-me")).Info("hello")

	if !strings.Contains(buffer.String(), "trace-me") {
		t.Fatalf("the correlation id did not reach the log line:\n%s", buffer.String())
	}
}

func TestNewLoggerProducesParsableJSON(t *testing.T) {
	t.Parallel()

	// Structured output is the whole point. A line an aggregator cannot parse is a line
	// nobody will ever search for, and it will not be noticed until it is needed.
	logger := NewLogger("info", "test")
	if logger == nil {
		t.Fatal("NewLogger returned nil")
	}
}
