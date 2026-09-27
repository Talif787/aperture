package httpx

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strconv"
	"strings"
	"testing"

	"github.com/talif/aperture/backend/internal/metrics"
	"github.com/talif/aperture/backend/internal/ratelimit"
	"github.com/talif/aperture/backend/internal/tenancy"
)

const (
	tenantA = "11111111-1111-4111-a111-111111111111"
	tenantB = "22222222-2222-4222-a222-222222222222"
)

func scopedTo(tenantID string) *http.Request {
	request := httptest.NewRequest(http.MethodGet, "/v1/sync/changes", nil)
	ctx := tenancy.WithPrincipal(request.Context(), tenancy.Principal{
		TenantID: tenantID,
		UserID:   "user-1",
		Roles:    []string{"inspector"},
	})
	return request.WithContext(ctx)
}

func okHandler() http.Handler {
	return http.HandlerFunc(func(writer http.ResponseWriter, _ *http.Request) {
		writer.WriteHeader(http.StatusOK)
	})
}

func TestRequestsWithinTheBudgetPass(t *testing.T) {
	t.Parallel()

	limiter := ratelimit.New(ratelimit.Config{PerSecond: 1, Burst: 3})
	handler := WithRateLimit(limiter, nil)(okHandler())

	for i := 0; i < 3; i++ {
		response := httptest.NewRecorder()
		handler.ServeHTTP(response, scopedTo(tenantA))

		if response.Code != http.StatusOK {
			t.Fatalf("request %d got %d", i+1, response.Code)
		}
	}
}

func TestRequestsBeyondTheBudgetAreRefused(t *testing.T) {
	t.Parallel()

	limiter := ratelimit.New(ratelimit.Config{PerSecond: 0.001, Burst: 1})
	handler := WithRateLimit(limiter, nil)(okHandler())

	handler.ServeHTTP(httptest.NewRecorder(), scopedTo(tenantA))

	response := httptest.NewRecorder()
	handler.ServeHTTP(response, scopedTo(tenantA))

	if response.Code != http.StatusTooManyRequests {
		t.Fatalf("expected 429, got %d", response.Code)
	}
}

func TestARefusalAdvertisesWhenToRetry(t *testing.T) {
	t.Parallel()

	limiter := ratelimit.New(ratelimit.Config{PerSecond: 1, Burst: 1})
	handler := WithRateLimit(limiter, nil)(okHandler())

	handler.ServeHTTP(httptest.NewRecorder(), scopedTo(tenantA))

	response := httptest.NewRecorder()
	handler.ServeHTTP(response, scopedTo(tenantA))

	// A client told only "no" backs off blindly and usually too long. One told how long
	// retries once, correctly, which is the difference between a fleet recovering in
	// seconds and a fleet recovering in minutes.
	header := response.Header().Get("Retry-After")
	seconds, err := strconv.Atoi(header)
	if err != nil {
		t.Fatalf("Retry-After was %q, which is not an integer", header)
	}
	if seconds < 1 {
		t.Fatalf("Retry-After was %d; RFC 9110 has no sub-second form, so it must be at least 1", seconds)
	}
}

func TestARefusalUsesTheStandardEnvelope(t *testing.T) {
	t.Parallel()

	limiter := ratelimit.New(ratelimit.Config{PerSecond: 1, Burst: 1})
	handler := WithRateLimit(limiter, nil)(okHandler())

	handler.ServeHTTP(httptest.NewRecorder(), scopedTo(tenantA))

	response := httptest.NewRecorder()
	handler.ServeHTTP(response, scopedTo(tenantA))

	var body struct {
		Error struct {
			Code      string `json:"code"`
			Retryable bool   `json:"retryable"`
			Details   struct {
				RetryAfterSeconds int `json:"retry_after_seconds"`
			} `json:"details"`
		} `json:"error"`
	}

	if err := json.Unmarshal(response.Body.Bytes(), &body); err != nil {
		t.Fatalf("the body was not the standard envelope: %v\n%s", err, response.Body.String())
	}

	if body.Error.Code != "RATE_LIMITED" {
		t.Fatalf("code was %q", body.Error.Code)
	}

	// Explicitly retryable. The sync engine dead-letters permanent rejections, so a
	// throttle that did not say it was transient would make a device discard work it
	// should simply resend.
	if !body.Error.Retryable {
		t.Fatal("a throttle was not marked retryable")
	}
	if body.Error.Details.RetryAfterSeconds < 1 {
		t.Fatal("the envelope did not carry a retry delay")
	}
}

func TestOneTenantCannotStarveAnother(t *testing.T) {
	t.Parallel()

	limiter := ratelimit.New(ratelimit.Config{PerSecond: 0.001, Burst: 1})
	handler := WithRateLimit(limiter, nil)(okHandler())

	handler.ServeHTTP(httptest.NewRecorder(), scopedTo(tenantA))

	exhausted := httptest.NewRecorder()
	handler.ServeHTTP(exhausted, scopedTo(tenantA))
	if exhausted.Code != http.StatusTooManyRequests {
		t.Fatalf("tenant A was not throttled: %d", exhausted.Code)
	}

	// The property the whole design exists for. Keying on the listener, or on an address,
	// would mean one carrier's device fleet taking down every other customer.
	other := httptest.NewRecorder()
	handler.ServeHTTP(other, scopedTo(tenantB))
	if other.Code != http.StatusOK {
		t.Fatalf("tenant B was refused because tenant A was noisy: %d", other.Code)
	}
}

func TestAnUnscopedRequestPassesThrough(t *testing.T) {
	t.Parallel()

	limiter := ratelimit.New(ratelimit.Config{PerSecond: 0.001, Burst: 0})
	handler := WithRateLimit(limiter, nil)(okHandler())

	response := httptest.NewRecorder()
	handler.ServeHTTP(response, httptest.NewRequest(http.MethodGet, "/v1/sync/changes", nil))

	// No verified tenant means this middleware is mounted in the wrong place. The handler
	// behind rejects an unscoped request itself, so passing through turns a wiring mistake
	// into a 401 rather than into a total outage.
	if response.Code != http.StatusOK {
		t.Fatalf("an unscoped request was refused with %d", response.Code)
	}
}

func TestThrottlingIsCountedWithoutATenantLabel(t *testing.T) {
	t.Parallel()

	registry := metrics.NewRegistry()
	limiter := ratelimit.New(ratelimit.Config{PerSecond: 1, Burst: 1})
	handler := WithRateLimit(limiter, metrics.NewRecorder(registry))(okHandler())

	handler.ServeHTTP(httptest.NewRecorder(), scopedTo(tenantA))
	handler.ServeHTTP(httptest.NewRecorder(), scopedTo(tenantA))

	var builder strings.Builder
	_ = registry.Render(&builder)
	output := builder.String()

	if !strings.Contains(output, `aperture_http_throttled_total{route="/v1/sync/changes"} 1`) {
		t.Fatalf("throttling was not counted:\n%s", output)
	}

	// Tenant identifiers are unbounded. This counter rises fastest when the system is
	// already under strain, which makes it the worst possible place to blow up cardinality.
	if strings.Contains(output, tenantA) {
		t.Fatalf("the throttle counter is labelled by tenant:\n%s", output)
	}
}

func BenchmarkRateLimitMiddleware(b *testing.B) {
	limiter := ratelimit.New(ratelimit.Config{PerSecond: 1e9, Burst: 1e9})
	handler := WithRateLimit(limiter, nil)(okHandler())
	request := scopedTo(tenantA)

	b.ReportAllocs()
	b.ResetTimer()

	for i := 0; i < b.N; i++ {
		handler.ServeHTTP(httptest.NewRecorder(), request)
	}
}
