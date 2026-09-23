package httpx

import (
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

	"github.com/talif/aperture/backend/internal/metrics"
)

func TestRouteTemplateReplacesIdentifiers(t *testing.T) {
	t.Parallel()

	cases := map[string]string{
		"/v1/me":           "/v1/me",
		"/v1/sync/changes": "/v1/sync/changes",
		"/v1/sync/deltas":  "/v1/sync/deltas",
		"/healthz":         "/healthz",
		"/v1/sync/changes/11111111-1111-4111-a111-11111111": "other",
		"/nonsense":         "other",
		"/v1/../etc/passwd": "other",
	}

	for path, expected := range cases {
		if actual := RouteTemplate(path); actual != expected {
			t.Errorf("RouteTemplate(%q) = %q, want %q", path, actual, expected)
		}
	}
}

func TestUnknownPathsCollapse(t *testing.T) {
	t.Parallel()

	// A caller can request any path they like. Passing unknown ones through would hand
	// them direct control of the series count, which is the same outage as an unbounded
	// label with an attacker holding the dial.
	for i := 0; i < 500; i++ {
		if RouteTemplate("/attacker/controlled/"+strings.Repeat("x", i%40)) != "other" {
			t.Fatal("an unknown path was not collapsed")
		}
	}
}

func TestMetricsMiddlewareRecordsEveryRequest(t *testing.T) {
	t.Parallel()

	registry := metrics.NewRegistry()
	recorder := metrics.NewRecorder(registry)

	handler := WithMetrics(recorder)(http.HandlerFunc(
		func(writer http.ResponseWriter, _ *http.Request) {
			writer.WriteHeader(http.StatusTeapot)
		}))

	response := httptest.NewRecorder()
	handler.ServeHTTP(response, httptest.NewRequest(http.MethodGet, "/v1/me", nil))

	var builder strings.Builder
	if err := registry.Render(&builder); err != nil {
		t.Fatalf("rendering: %v", err)
	}
	output := builder.String()

	if !strings.Contains(output, `aperture_http_requests_total{method="GET",route="/v1/me",status="418"} 1`) {
		t.Fatalf("request was not counted:\n%s", output)
	}
}

func TestDurationIsNotLabelledByStatus(t *testing.T) {
	t.Parallel()

	registry := metrics.NewRegistry()
	recorder := metrics.NewRecorder(registry)

	handler := WithMetrics(recorder)(http.HandlerFunc(
		func(writer http.ResponseWriter, _ *http.Request) {
			writer.WriteHeader(http.StatusInternalServerError)
		}))

	handler.ServeHTTP(httptest.NewRecorder(), httptest.NewRequest(http.MethodGet, "/v1/me", nil))

	var builder strings.Builder
	_ = registry.Render(&builder)

	// Mixing status into the latency histogram makes a quantile meaningless when the error
	// rate moves: fast failures drag the distribution down exactly when things are going
	// wrong, and the graph improves during an incident.
	if strings.Contains(builder.String(), `aperture_http_request_duration_seconds_count{method="GET",route="/v1/me",status=`) {
		t.Fatalf("duration must not be labelled by status:\n%s", builder.String())
	}
}

func TestUnauthenticatedRequestsAreStillCounted(t *testing.T) {
	t.Parallel()

	registry := metrics.NewRegistry()
	recorder := metrics.NewRecorder(registry)

	// Middleware placed outside authentication. A metrics layer that only sees
	// authenticated traffic cannot show an authentication outage, which is the moment a
	// graph is most wanted.
	handler := WithMetrics(recorder)(http.HandlerFunc(
		func(writer http.ResponseWriter, _ *http.Request) {
			writer.WriteHeader(http.StatusUnauthorized)
		}))

	handler.ServeHTTP(httptest.NewRecorder(), httptest.NewRequest(http.MethodGet, "/v1/me", nil))

	var builder strings.Builder
	_ = registry.Render(&builder)

	if !strings.Contains(builder.String(), `status="401"`) {
		t.Fatalf("a rejected request was not counted:\n%s", builder.String())
	}
}

func TestHandlerServesExpositionFormat(t *testing.T) {
	t.Parallel()

	registry := metrics.NewRegistry()
	recorder := metrics.NewRecorder(registry)
	recorder.SyncOperationApplied("applied")

	response := httptest.NewRecorder()
	recorder.Handler().ServeHTTP(response, httptest.NewRequest(http.MethodGet, "/metrics", nil))

	if contentType := response.Header().Get("Content-Type"); !strings.HasPrefix(contentType, "text/plain") {
		t.Fatalf("unexpected content type %q", contentType)
	}
	if !strings.Contains(response.Body.String(), `aperture_sync_operations_total{status="applied"} 1`) {
		t.Fatalf("unexpected body:\n%s", response.Body.String())
	}
}

func TestLatencyBucketsStraddleTheObjective(t *testing.T) {
	t.Parallel()

	// Buckets decide which questions the data can answer. With a 300 millisecond
	// objective and no boundary at it, every breach and every comfortable pass fall in the
	// same bucket and the histogram cannot report compliance at all.
	var found bool
	for _, bound := range metrics.LatencyBuckets {
		if bound == 0.300 {
			found = true
		}
	}
	if !found {
		t.Fatal("no bucket boundary at the 300ms objective")
	}
}
