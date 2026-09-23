package httpx

import (
	"net/http"
	"regexp"
	"strings"
	"time"

	"github.com/talif/aperture/backend/internal/metrics"
)

// identifierPattern matches the path segments that must never become label values.
//
// UUIDs, ULIDs, numeric identifiers, and the content-addressed hashes this product uses.
// Anything matching is replaced before the path is used as a metric label.
var identifierPattern = regexp.MustCompile(
	`^(?:[0-9a-fA-F-]{8,}|[0-9A-HJKMNP-TV-Z]{26}|\d+|f-[\w-]+)$`,
)

// WithMetrics records one observation per request.
//
// Placed outside the authentication middleware so rejected requests are counted too. A
// metrics layer that only sees authenticated traffic cannot show you an authentication
// outage, which is the moment you most want a graph.
func WithMetrics(recorder *metrics.Recorder) Middleware {
	return func(next http.Handler) http.Handler {
		return http.HandlerFunc(func(writer http.ResponseWriter, request *http.Request) {
			started := time.Now()
			wrapped := &statusRecorder{ResponseWriter: writer, status: http.StatusOK}

			next.ServeHTTP(wrapped, request)

			recorder.RequestCompleted(
				request.Method,
				RouteTemplate(request.URL.Path),
				wrapped.status,
				time.Since(started),
			)
		})
	}
}

// RouteTemplate reduces a request path to a bounded label value.
//
// This function is the difference between a working monitoring system and one that falls
// over. Labelling by raw path produces one time series per entity identifier, which is
// unbounded: the series count grows with the data, Prometheus stores every one, and the
// failure arrives as a monitoring outage during whatever incident made the traffic spike.
//
// Unknown paths collapse to "other" rather than passing through. A caller can request any
// path they like, so passing unknown ones through would hand an attacker direct control of
// the series count.
func RouteTemplate(path string) string {
	segments := strings.Split(strings.Trim(path, "/"), "/")

	for i, segment := range segments {
		if identifierPattern.MatchString(segment) {
			segments[i] = ":id"
		}
	}

	template := "/" + strings.Join(segments, "/")

	if !knownRoutes[template] {
		return "other"
	}
	return template
}

// knownRoutes is the allow-list. Adding an endpoint means adding it here, deliberately,
// which is the point: the set of exported series is reviewable rather than emergent.
var knownRoutes = map[string]bool{
	"/healthz":         true,
	"/readyz":          true,
	"/version":         true,
	"/v1/me":           true,
	"/v1/sync/changes": true,
	"/v1/sync/deltas":  true,
}
