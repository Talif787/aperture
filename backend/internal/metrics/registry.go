// Package metrics emits Prometheus exposition format from the standard library.
//
// No client dependency. The format is a few lines of text, the semantics that matter are
// cardinality control and bucket choice rather than encoding, and this project has already
// spent enough on dependency resolution. A hand-written registry also makes the one thing
// that actually causes outages, unbounded label cardinality, impossible to get wrong by
// accident: it is enforced here rather than left to whoever adds the next counter.
package metrics

import (
	"fmt"
	"io"
	"sort"
	"strconv"
	"strings"
	"sync"
)

// MaxSeriesPerMetric bounds how many distinct label combinations one metric may produce.
//
// This limit is the whole reason to hand-write a registry. A counter labelled with
// something unbounded, a raw URL path, a tenant identifier, an error message, produces a
// new time series per distinct value. Prometheus stores each one, and a metric that looks
// harmless in development takes down the monitoring system in production, at which point
// you have lost observability precisely when you need it.
//
// Beyond the limit, further combinations collapse into a single `overflow` series rather
// than being dropped. Dropping would understate the totals silently; collapsing keeps the
// arithmetic correct and makes the overflow visible.
const MaxSeriesPerMetric = 200

// OverflowLabel marks the collapsed series.
const OverflowLabel = "overflow"

// Registry holds every metric the process exports.
type Registry struct {
	mu         sync.RWMutex
	counters   map[string]*counter
	gauges     map[string]*gauge
	histograms map[string]*histogram
	order      []string
}

// NewRegistry builds an empty registry.
func NewRegistry() *Registry {
	return &Registry{
		counters:   make(map[string]*counter),
		gauges:     make(map[string]*gauge),
		histograms: make(map[string]*histogram),
	}
}

type series struct {
	labels string
	value  float64
}

type counter struct {
	help   string
	values map[string]float64
}

type gauge struct {
	help   string
	values map[string]float64
}

type histogram struct {
	help    string
	bounds  []float64
	buckets map[string][]uint64
	sums    map[string]float64
	counts  map[string]uint64
}

// Labels is one label set. A map rather than a slice so call sites name what they mean.
type Labels map[string]string

// Counter increments a monotonic counter.
func (r *Registry) Counter(name, help string, labels Labels, delta float64) {
	r.mu.Lock()
	defer r.mu.Unlock()

	metric, ok := r.counters[name]
	if !ok {
		metric = &counter{help: help, values: make(map[string]float64)}
		r.counters[name] = metric
		r.order = append(r.order, name)
	}

	key := r.boundedKey(name, labels, len(metric.values))
	metric.values[key] += delta
}

// Gauge sets a value that can go up or down.
func (r *Registry) Gauge(name, help string, labels Labels, value float64) {
	r.mu.Lock()
	defer r.mu.Unlock()

	metric, ok := r.gauges[name]
	if !ok {
		metric = &gauge{help: help, values: make(map[string]float64)}
		r.gauges[name] = metric
		r.order = append(r.order, name)
	}

	key := r.boundedKey(name, labels, len(metric.values))
	metric.values[key] = value
}

// Observe records a value into a histogram.
func (r *Registry) Observe(name, help string, bounds []float64, labels Labels, value float64) {
	r.mu.Lock()
	defer r.mu.Unlock()

	metric, ok := r.histograms[name]
	if !ok {
		metric = &histogram{
			help:    help,
			bounds:  bounds,
			buckets: make(map[string][]uint64),
			sums:    make(map[string]float64),
			counts:  make(map[string]uint64),
		}
		r.histograms[name] = metric
		r.order = append(r.order, name)
	}

	key := r.boundedKey(name, labels, len(metric.counts))

	if _, exists := metric.buckets[key]; !exists {
		metric.buckets[key] = make([]uint64, len(metric.bounds))
	}

	for i, bound := range metric.bounds {
		if value <= bound {
			metric.buckets[key][i]++
		}
	}
	metric.sums[key] += value
	metric.counts[key]++
}

// boundedKey renders a label set, collapsing to the overflow series past the limit.
func (r *Registry) boundedKey(name string, labels Labels, existing int) string {
	key := renderLabels(labels)

	if existing < MaxSeriesPerMetric {
		return key
	}

	// Already at the limit. An existing series keeps its identity; anything new collapses.
	if r.hasSeries(name, key) {
		return key
	}
	return renderLabels(Labels{"series": OverflowLabel})
}

func (r *Registry) hasSeries(name, key string) bool {
	if metric, ok := r.counters[name]; ok {
		_, exists := metric.values[key]
		return exists
	}
	if metric, ok := r.gauges[name]; ok {
		_, exists := metric.values[key]
		return exists
	}
	if metric, ok := r.histograms[name]; ok {
		_, exists := metric.counts[key]
		return exists
	}
	return false
}

// renderLabels produces a deterministic label string.
//
// Sorted by name, because Prometheus treats label order as insignificant but a scrape diff
// and a test assertion both treat it as very significant indeed.
func renderLabels(labels Labels) string {
	if len(labels) == 0 {
		return ""
	}

	names := make([]string, 0, len(labels))
	for name := range labels {
		names = append(names, name)
	}
	sort.Strings(names)

	parts := make([]string, 0, len(names))
	for _, name := range names {
		// %s with explicit quotes, not %q. Go's %q escapes far more than the exposition
		// format defines, so a tab would become \t and a control character \x00, neither
		// of which Prometheus recognises. It also double-escapes what escapeValue has
		// already handled. The format defines exactly three escapes, and escapeValue
		// produces exactly those.
		parts = append(parts, fmt.Sprintf(`%s="%s"`, name, escapeValue(labels[name])))
	}

	return "{" + strings.Join(parts, ",") + "}"
}

func escapeValue(value string) string {
	replacer := strings.NewReplacer(`\`, `\\`, `"`, `\"`, "\n", `\n`)
	return replacer.Replace(value)
}

// WriteTo renders the registry in Prometheus exposition format.
//
// Output is deterministic: metrics in registration order, series sorted within each. A
// scrape endpoint whose output reorders between calls makes every diff unreadable and
// every test flaky.
func (r *Registry) WriteTo(writer io.Writer) error {
	r.mu.RLock()
	defer r.mu.RUnlock()

	for _, name := range r.order {
		var err error

		switch {
		case r.counters[name] != nil:
			err = writeSimple(writer, name, "counter", r.counters[name].help, r.counters[name].values)
		case r.gauges[name] != nil:
			err = writeSimple(writer, name, "gauge", r.gauges[name].help, r.gauges[name].values)
		case r.histograms[name] != nil:
			err = writeHistogram(writer, name, r.histograms[name])
		}

		if err != nil {
			return err
		}
	}

	return nil
}

func writeSimple(writer io.Writer, name, kind, help string, values map[string]float64) error {
	if _, err := fmt.Fprintf(writer, "# HELP %s %s\n# TYPE %s %s\n", name, help, name, kind); err != nil {
		return err
	}

	for _, entry := range sortedSeries(values) {
		if _, err := fmt.Fprintf(writer, "%s%s %s\n",
			name, entry.labels, strconv.FormatFloat(entry.value, 'g', -1, 64)); err != nil {
			return err
		}
	}

	return nil
}

func writeHistogram(writer io.Writer, name string, metric *histogram) error {
	if _, err := fmt.Fprintf(writer,
		"# HELP %s %s\n# TYPE %s histogram\n", name, metric.help, name); err != nil {
		return err
	}

	keys := make([]string, 0, len(metric.counts))
	for key := range metric.counts {
		keys = append(keys, key)
	}
	sort.Strings(keys)

	for _, key := range keys {
		for i, bound := range metric.bounds {
			if err := writeBucket(writer, name, key, formatBound(bound), metric.buckets[key][i]); err != nil {
				return err
			}
		}

		// The +Inf bucket is mandatory and equals the total count. Omitting it makes the
		// histogram silently unusable for quantile estimation.
		if err := writeBucket(writer, name, key, "+Inf", metric.counts[key]); err != nil {
			return err
		}

		if _, err := fmt.Fprintf(writer, "%s_sum%s %s\n%s_count%s %d\n",
			name, key, strconv.FormatFloat(metric.sums[key], 'g', -1, 64),
			name, key, metric.counts[key]); err != nil {
			return err
		}
	}

	return nil
}

func writeBucket(writer io.Writer, name, labels, bound string, count uint64) error {
	inner := fmt.Sprintf(`le=%q`, bound)

	if labels == "" {
		_, err := fmt.Fprintf(writer, "%s_bucket{%s} %d\n", name, inner, count)
		return err
	}

	merged := labels[:len(labels)-1] + "," + inner + "}"
	_, err := fmt.Fprintf(writer, "%s_bucket%s %d\n", name, merged, count)
	return err
}

func formatBound(bound float64) string {
	return strconv.FormatFloat(bound, 'g', -1, 64)
}

func sortedSeries(values map[string]float64) []series {
	entries := make([]series, 0, len(values))
	for labels, value := range values {
		entries = append(entries, series{labels: labels, value: value})
	}
	sort.Slice(entries, func(i, j int) bool { return entries[i].labels < entries[j].labels })
	return entries
}
