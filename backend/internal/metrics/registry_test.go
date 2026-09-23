package metrics

import (
	"strconv"
	"strings"
	"testing"
)

func render(t *testing.T, registry *Registry) string {
	t.Helper()

	var builder strings.Builder
	if err := registry.WriteTo(&builder); err != nil {
		t.Fatalf("rendering: %v", err)
	}
	return builder.String()
}

func TestCounterAccumulates(t *testing.T) {
	t.Parallel()

	registry := NewRegistry()
	registry.Counter("requests_total", "Requests.", Labels{"route": "/v1/me"}, 1)
	registry.Counter("requests_total", "Requests.", Labels{"route": "/v1/me"}, 2)

	output := render(t, registry)
	if !strings.Contains(output, `requests_total{route="/v1/me"} 3`) {
		t.Fatalf("expected an accumulated counter, got:\n%s", output)
	}
}

func TestOutputIsDeterministic(t *testing.T) {
	t.Parallel()

	registry := NewRegistry()
	for _, route := range []string{"/z", "/a", "/m"} {
		registry.Counter("requests_total", "Requests.", Labels{"route": route}, 1)
	}

	// Map iteration order in Go is deliberately randomised. An endpoint whose output
	// reorders between scrapes makes every diff unreadable and every test flaky, so the
	// registry sorts.
	first := render(t, registry)
	for i := 0; i < 20; i++ {
		if render(t, registry) != first {
			t.Fatal("output is not stable across renders")
		}
	}

	if strings.Index(first, "/a") > strings.Index(first, "/m") {
		t.Fatalf("series are not sorted:\n%s", first)
	}
}

func TestLabelsAreSortedByName(t *testing.T) {
	t.Parallel()

	registry := NewRegistry()
	registry.Counter("thing_total", "Thing.", Labels{"zebra": "1", "alpha": "2"}, 1)

	// Prometheus treats label order as insignificant. A test assertion and a scrape diff
	// do not, so the order is fixed here rather than left to the map.
	if !strings.Contains(render(t, registry), `thing_total{alpha="2",zebra="1"} 1`) {
		t.Fatalf("labels are not sorted:\n%s", render(t, registry))
	}
}

func TestCardinalityIsBounded(t *testing.T) {
	t.Parallel()

	registry := NewRegistry()

	// Simulates the classic outage: a label fed from unbounded input.
	for i := 0; i < MaxSeriesPerMetric*3; i++ {
		registry.Counter("unbounded_total", "Unbounded.",
			Labels{"id": strings.Repeat("x", 1) + string(rune('a'+i%26)) + string(rune(i))}, 1)
	}

	output := render(t, registry)
	lines := 0
	for _, line := range strings.Split(output, "\n") {
		if strings.HasPrefix(line, "unbounded_total{") {
			lines++
		}
	}

	// At the limit plus the overflow series. Prometheus stores one time series per label
	// combination, so an unbounded label takes down the monitoring system before it takes
	// down the service, which is the worst possible ordering.
	if lines > MaxSeriesPerMetric+1 {
		t.Fatalf("cardinality was not bounded: %d series", lines)
	}
	if !strings.Contains(output, OverflowLabel) {
		t.Fatalf("overflow series is missing:\n%s", output[:400])
	}
}

func TestOverflowPreservesTotals(t *testing.T) {
	t.Parallel()

	registry := NewRegistry()
	total := MaxSeriesPerMetric * 2

	for i := 0; i < total; i++ {
		registry.Counter("counted_total", "Counted.", Labels{"id": strings.Repeat("a", i%50) + string(rune(i))}, 1)
	}

	output := render(t, registry)
	var sum float64
	for _, line := range strings.Split(output, "\n") {
		if !strings.HasPrefix(line, "counted_total{") {
			continue
		}
		parts := strings.Fields(line)
		value, err := strconv.ParseFloat(parts[len(parts)-1], 64)
		if err != nil {
			t.Fatalf("parsing %q: %v", line, err)
		}
		sum += value
	}

	// Collapsing rather than dropping. Dropping would understate the total silently, and a
	// counter that quietly stops counting is worse than one that is obviously wrong.
	if int(sum) != total {
		t.Fatalf("overflow lost observations: counted %v of %d", sum, total)
	}
}

func TestHistogramEmitsCumulativeBuckets(t *testing.T) {
	t.Parallel()

	registry := NewRegistry()
	bounds := []float64{0.1, 0.5, 1}

	for _, value := range []float64{0.05, 0.2, 0.7, 5} {
		registry.Observe("latency_seconds", "Latency.", bounds, Labels{"route": "/v1/me"}, value)
	}

	output := render(t, registry)

	// Prometheus buckets are cumulative: le="0.5" counts everything at or below 0.5, not
	// just what falls between 0.1 and 0.5. Getting this wrong produces quantiles that look
	// plausible and are wrong.
	for expected, want := range map[string]string{
		`le="0.1"`:  "1",
		`le="0.5"`:  "2",
		`le="1"`:    "3",
		`le="+Inf"`: "4",
	} {
		if !strings.Contains(output, expected+"} "+want) {
			t.Fatalf("bucket %s should be %s:\n%s", expected, want, output)
		}
	}

	if !strings.Contains(output, "latency_seconds_count{route=\"/v1/me\"} 4") {
		t.Fatalf("count is wrong:\n%s", output)
	}
}

func TestHistogramAlwaysEmitsInfinityBucket(t *testing.T) {
	t.Parallel()

	registry := NewRegistry()
	registry.Observe("latency_seconds", "Latency.", []float64{0.1}, nil, 0.05)

	// Mandatory in the format. Without it the histogram is silently unusable for quantile
	// estimation, and nothing complains: the scrape succeeds and the graph is empty.
	if !strings.Contains(render(t, registry), `le="+Inf"`) {
		t.Fatal("the +Inf bucket is missing")
	}
}

func TestLabelValuesAreEscaped(t *testing.T) {
	t.Parallel()

	registry := NewRegistry()
	registry.Counter("thing_total", "Thing.", Labels{"path": `a"b\c`}, 1)

	// An unescaped quote produces a line Prometheus rejects, and the rejection is of the
	// whole scrape rather than the one series.
	output := render(t, registry)
	if !strings.Contains(output, `path="a\"b\\c"`) {
		t.Fatalf("value was not escaped:\n%s", output)
	}
}

func TestGaugeReplacesRatherThanAccumulates(t *testing.T) {
	t.Parallel()

	registry := NewRegistry()
	registry.Gauge("queue_depth", "Depth.", nil, 5)
	registry.Gauge("queue_depth", "Depth.", nil, 2)

	if !strings.Contains(render(t, registry), "queue_depth 2") {
		t.Fatalf("a gauge must replace, not accumulate:\n%s", render(t, registry))
	}
}

func TestHelpAndTypeArePresent(t *testing.T) {
	t.Parallel()

	registry := NewRegistry()
	registry.Counter("requests_total", "Requests completed.", nil, 1)

	output := render(t, registry)
	if !strings.Contains(output, "# HELP requests_total Requests completed.") ||
		!strings.Contains(output, "# TYPE requests_total counter") {
		t.Fatalf("metadata is missing:\n%s", output)
	}
}
