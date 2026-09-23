package metrics

import (
	"net/http"
	"strconv"
	"time"
)

// LatencyBuckets are chosen from the service's own latency targets rather than from a
// default ladder.
//
// Buckets decide what questions the data can answer. A histogram whose boundaries do not
// straddle the objective cannot tell you whether the objective was met: if the target is
// 300 milliseconds and the nearest boundaries are 250 and 500, every breach and every
// comfortable pass land in the same bucket.
var LatencyBuckets = []float64{
	0.005, 0.010, 0.025, 0.050, 0.100,
	0.200, 0.300, // the sync read and write objectives
	0.500, 1.000, 2.500, 5.000, 10.000,
}

// Recorder exposes the handful of measurements the service actually reports.
//
// A narrow surface on purpose. A registry anyone can write to accumulates metrics nobody
// reads and label sets nobody bounded; naming the measurements here keeps the exported
// set reviewable.
type Recorder struct {
	registry *Registry
}

// NewRecorder wraps a registry.
func NewRecorder(registry *Registry) *Recorder {
	return &Recorder{registry: registry}
}

// Registry exposes the underlying registry for the scrape handler.
func (r *Recorder) Registry() *Registry { return r.registry }

// RequestCompleted records one HTTP request.
//
// `route` must be the route template, never the request path. Labelling by path means one
// series per entity identifier, which is unbounded by construction: a hundred thousand
// inspections becomes a hundred thousand time series, and the monitoring system fails
// before the service does.
func (r *Recorder) RequestCompleted(method, route string, status int, duration time.Duration) {
	labels := Labels{
		"method": method,
		"route":  route,
		"status": strconv.Itoa(status),
	}

	r.registry.Counter("aperture_http_requests_total",
		"HTTP requests completed, by method, route template, and status.", labels, 1)

	// Duration is labelled without status. Mixing them makes a latency quantile meaningless
	// when the error rate moves, because fast failures drag the distribution down exactly
	// when things are going wrong.
	r.registry.Observe("aperture_http_request_duration_seconds",
		"HTTP request duration in seconds, by method and route template.",
		LatencyBuckets,
		Labels{"method": method, "route": route},
		duration.Seconds())
}

// SyncOperationApplied records the outcome of one pushed operation.
//
// `replayed` is counted separately from `applied` for the same reason the API reports them
// separately: a rising replay rate is the signature of a client retry storm, and folding
// it into applied hides exactly the signal an operator needs when a fleet reconnects at
// shift end.
func (r *Recorder) SyncOperationApplied(status string) {
	r.registry.Counter("aperture_sync_operations_total",
		"Sync operations by outcome: applied, replayed, conflict, rejected.",
		Labels{"status": status}, 1)
}

// SyncConflictDetected records a conflict, by the field that caused it.
//
// Bounded by construction: field keys come from a template, not from user input. Worth
// stating because it is the one place here where a label could plausibly come from data.
func (r *Recorder) SyncConflictDetected(field string) {
	r.registry.Counter("aperture_sync_conflicts_total",
		"Concurrent changes that required resolution, by field.",
		Labels{"field": field}, 1)
}

// ChangesPulled records how much a device pulled.
func (r *Recorder) ChangesPulled(count int) {
	r.registry.Counter("aperture_sync_changes_pulled_total",
		"Change records returned to devices.", nil, float64(count))
}

// AuthenticationFailed records a rejected token.
//
// Labelled by reason so a spike in expiry (a clock problem) is distinguishable from a
// spike in bad signatures (a key rotation, or an attack). The reason is never returned to
// the caller, so this is the only place the distinction exists.
func (r *Recorder) AuthenticationFailed(reason string) {
	r.registry.Counter("aperture_auth_failures_total",
		"Rejected bearer tokens, by reason.", Labels{"reason": reason}, 1)
}

// Handler serves the registry.
//
// Not mounted on the public listener by the caller. A metrics endpoint discloses request
// volumes, error rates, and tenant activity patterns, which is competitive intelligence
// about a customer's operations even though it contains no inspection data.
func (r *Recorder) Handler() http.Handler {
	return http.HandlerFunc(func(writer http.ResponseWriter, _ *http.Request) {
		writer.Header().Set("Content-Type", "text/plain; version=0.0.4; charset=utf-8")
		writer.WriteHeader(http.StatusOK)
		_ = r.registry.Render(writer)
	})
}
