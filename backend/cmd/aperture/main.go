// Command aperture is the Aperture backend service.
//
// One binary, modular internal packages. The domains in this system share transactions:
// applying a delta writes the entity, increments its version, appends an audit row, and
// enqueues derived work, all atomically. Splitting those across services would replace a
// database transaction with a distributed one, which is a large increase in complexity in
// exchange for independent deployability that a team of this size does not need yet.
//
// The seams are drawn where a split would happen, and the trigger for the first one
// (media processing diverging in resource shape) is recorded in the architecture document.
package main

import (
	"context"
	"encoding/json"
	"errors"
	"log/slog"
	"net/http"
	"os"
	"os/signal"
	"sync/atomic"
	"syscall"
	"time"

	"github.com/talif/aperture/backend/internal/httpx"
	"github.com/talif/aperture/backend/internal/obs"
)

const (
	readHeaderTimeout = 5 * time.Second
	readTimeout       = 15 * time.Second
	writeTimeout      = 20 * time.Second
	idleTimeout       = 60 * time.Second
	shutdownGrace     = 20 * time.Second
	maxRequestBytes   = 2 << 20 // 2 MiB, the sync batch ceiling
)

// buildVersion is injected at link time: -ldflags "-X main.buildVersion=$(git rev-parse --short HEAD)"
var buildVersion = "dev"

func main() {
	config := loadConfig()
	logger := obs.NewLogger(config.logLevel, config.environment)

	if err := run(config, logger); err != nil {
		logger.Error("fatal", slog.String("error", err.Error()))
		os.Exit(1)
	}
}

type config struct {
	addr        string
	logLevel    string
	environment string
}

func loadConfig() config {
	return config{
		addr:        envOrDefault("APERTURE_HTTP_ADDR", ":8080"),
		logLevel:    envOrDefault("APERTURE_LOG_LEVEL", "info"),
		environment: envOrDefault("APERTURE_ENVIRONMENT", "local"),
	}
}

func envOrDefault(key, fallback string) string {
	if value := os.Getenv(key); value != "" {
		return value
	}
	return fallback
}

func run(cfg config, logger *slog.Logger) error {
	// Readiness is tracked separately from liveness. Conflating them is a common mistake
	// with a specific bad outcome: a degraded dependency causes the orchestrator to kill
	// and restart a process that is working fine, turning a partial outage into a crash
	// loop. Liveness answers "is this process responsive", readiness answers "should it
	// receive traffic", and only the second one depends on the database.
	var ready atomic.Bool

	mux := http.NewServeMux()
	mux.HandleFunc("GET /healthz", func(writer http.ResponseWriter, _ *http.Request) {
		writeJSON(writer, http.StatusOK, map[string]string{
			"status":  "ok",
			"version": buildVersion,
		})
	})
	mux.HandleFunc("GET /readyz", func(writer http.ResponseWriter, _ *http.Request) {
		if !ready.Load() {
			writeJSON(writer, http.StatusServiceUnavailable, map[string]string{"status": "starting"})
			return
		}
		// Phase 6 adds the database and Redis probes here. Until those dependencies exist,
		// reporting ready once startup has completed is accurate rather than optimistic.
		writeJSON(writer, http.StatusOK, map[string]string{"status": "ready"})
	})
	mux.HandleFunc("GET /version", func(writer http.ResponseWriter, _ *http.Request) {
		writeJSON(writer, http.StatusOK, map[string]string{
			"version":     buildVersion,
			"environment": cfg.environment,
			"contract":    "v1",
		})
	})

	handler := httpx.Chain(mux,
		httpx.WithRecovery(logger),
		httpx.WithCorrelationID,
		httpx.WithAccessLog(logger),
		httpx.WithMaxBodySize(maxRequestBytes),
	)

	server := &http.Server{
		Addr:              cfg.addr,
		Handler:           handler,
		ReadHeaderTimeout: readHeaderTimeout,
		ReadTimeout:       readTimeout,
		WriteTimeout:      writeTimeout,
		IdleTimeout:       idleTimeout,
		ErrorLog:          slog.NewLogLogger(logger.Handler(), slog.LevelError),
	}

	serverErrors := make(chan error, 1)
	go func() {
		logger.Info("listening",
			slog.String("addr", cfg.addr),
			slog.String("version", buildVersion),
			slog.String("environment", cfg.environment),
		)
		ready.Store(true)

		if err := server.ListenAndServe(); err != nil && !errors.Is(err, http.ErrServerClosed) {
			serverErrors <- err
		}
	}()

	shutdown := make(chan os.Signal, 1)
	signal.Notify(shutdown, os.Interrupt, syscall.SIGTERM)

	select {
	case err := <-serverErrors:
		return err

	case signalReceived := <-shutdown:
		logger.Info("shutting down", slog.String("signal", signalReceived.String()))

		// Fail readiness first so the load balancer drains this instance before the
		// listener closes. Without the ordering, in-flight requests are cut rather than
		// completed, which on this system means a sync batch that the client must retry.
		ready.Store(false)

		ctx, cancel := context.WithTimeout(context.Background(), shutdownGrace)
		defer cancel()

		if err := server.Shutdown(ctx); err != nil {
			if closeErr := server.Close(); closeErr != nil {
				return errors.Join(err, closeErr)
			}
			return err
		}

		logger.Info("stopped cleanly")
		return nil
	}
}

func writeJSON(writer http.ResponseWriter, status int, body any) {
	writer.Header().Set("Content-Type", "application/json")
	writer.WriteHeader(status)
	if err := json.NewEncoder(writer).Encode(body); err != nil {
		// The status line is already written, so the only useful action left is to stop.
		return
	}
}
