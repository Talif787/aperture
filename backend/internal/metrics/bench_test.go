package metrics

import (
	"io"
	"strconv"
	"testing"
)

// The scrape path runs on a timer forever, so its cost is paid continuously rather than
// per request. A registry that renders slowly turns every scrape into a latency spike on
// the same process that is serving traffic.

func BenchmarkCounterHot(b *testing.B) {
	registry := NewRegistry()
	labels := Labels{"method": "GET", "route": "/v1/me", "status": "200"}

	b.ReportAllocs()
	b.ResetTimer()

	for i := 0; i < b.N; i++ {
		registry.Counter("requests_total", "Requests.", labels, 1)
	}
}

func BenchmarkObserve(b *testing.B) {
	registry := NewRegistry()
	labels := Labels{"method": "GET", "route": "/v1/me"}

	b.ReportAllocs()
	b.ResetTimer()

	for i := 0; i < b.N; i++ {
		registry.Observe("duration_seconds", "Duration.", LatencyBuckets, labels, 0.05)
	}
}

func BenchmarkRenderRealisticRegistry(b *testing.B) {
	registry := NewRegistry()

	// Roughly what this service exports: six metrics across a handful of routes, statuses,
	// and outcomes. Benchmarking an empty registry would measure nothing.
	for _, route := range []string{"/v1/me", "/v1/sync/changes", "/v1/sync/deltas", "other"} {
		for _, status := range []string{"200", "400", "401", "429", "500"} {
			registry.Counter("aperture_http_requests_total", "Requests.",
				Labels{"method": "GET", "route": route, "status": status}, 3)
		}
		for i := 0; i < 50; i++ {
			registry.Observe("aperture_http_request_duration_seconds", "Duration.",
				LatencyBuckets, Labels{"method": "GET", "route": route},
				float64(i)/100.0)
		}
	}
	for _, status := range []string{"applied", "replayed", "conflict", "rejected"} {
		registry.Counter("aperture_sync_operations_total", "Operations.",
			Labels{"status": status}, 7)
	}

	b.ReportAllocs()
	b.ResetTimer()

	for i := 0; i < b.N; i++ {
		_ = registry.Render(io.Discard)
	}
}

func BenchmarkRenderGrowingCardinality(b *testing.B) {
	registry := NewRegistry()

	// At the ceiling. The cost of rendering when a metric has hit its limit is the cost
	// during exactly the incident that pushed it there.
	for i := 0; i < MaxSeriesPerMetric; i++ {
		registry.Counter("bounded_total", "Bounded.", Labels{"n": strconv.Itoa(i)}, 1)
	}

	b.ReportAllocs()
	b.ResetTimer()

	for i := 0; i < b.N; i++ {
		_ = registry.Render(io.Discard)
	}
}
