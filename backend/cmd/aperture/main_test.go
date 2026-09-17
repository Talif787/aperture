package main

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"os"
	"testing"

	"github.com/talif/aperture/backend/internal/obs"
)

func TestEnvOrDefault(t *testing.T) {
	t.Parallel()

	if value := envOrDefault("APERTURE_TEST_ABSENT_KEY", "fallback"); value != "fallback" {
		t.Fatalf("expected the fallback, got %q", value)
	}
}

func TestEnvOrDefaultPrefersTheEnvironment(t *testing.T) {
	t.Setenv("APERTURE_TEST_PRESENT_KEY", "from-environment")

	if value := envOrDefault("APERTURE_TEST_PRESENT_KEY", "fallback"); value != "from-environment" {
		t.Fatalf("expected the environment value, got %q", value)
	}
}

func TestLoadConfigDefaults(t *testing.T) {
	for _, key := range []string{"APERTURE_HTTP_ADDR", "APERTURE_LOG_LEVEL", "APERTURE_ENVIRONMENT"} {
		if err := os.Unsetenv(key); err != nil {
			t.Fatalf("unsetenv %s: %v", key, err)
		}
	}

	cfg := loadConfig()

	if cfg.addr != ":8080" || cfg.logLevel != "info" || cfg.environment != "local" {
		t.Fatalf("unexpected defaults: %+v", cfg)
	}
}

func TestWriteErrorUsesTheContractEnvelope(t *testing.T) {
	t.Parallel()

	recorder := httptest.NewRecorder()
	request := httptest.NewRequest(http.MethodGet, "/nope", nil)
	request = request.WithContext(obs.WithCorrelationID(request.Context(), "corr-abc"))

	writeError(recorder, request, http.StatusNotFound, "NOT_FOUND", "No route matches this path.")

	if recorder.Code != http.StatusNotFound {
		t.Fatalf("expected 404, got %d", recorder.Code)
	}
	if got := recorder.Header().Get("Content-Type"); got != "application/json" {
		t.Fatalf("expected JSON, got %q", got)
	}

	var envelope struct {
		Error struct {
			Code          string `json:"code"`
			HTTPStatus    int    `json:"http_status"`
			Retryable     bool   `json:"retryable"`
			CorrelationID string `json:"correlation_id"`
		} `json:"error"`
	}
	if err := json.NewDecoder(recorder.Body).Decode(&envelope); err != nil {
		t.Fatalf("body is not the error envelope: %v", err)
	}

	// The client decodes this shape. A plain-text 404 would be classified as a transport
	// anomaly rather than as an API error, so a mistyped path would surface as a corrupt
	// response.
	if envelope.Error.Code != "NOT_FOUND" || envelope.Error.HTTPStatus != 404 {
		t.Fatalf("unexpected envelope: %+v", envelope.Error)
	}
	if envelope.Error.CorrelationID != "corr-abc" {
		t.Fatalf("correlation id not propagated: %q", envelope.Error.CorrelationID)
	}
	if envelope.Error.Retryable {
		t.Fatal("a 404 must not be advertised as retryable")
	}
}
