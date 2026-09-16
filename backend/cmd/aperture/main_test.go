package main

import (
	"os"
	"testing"
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
