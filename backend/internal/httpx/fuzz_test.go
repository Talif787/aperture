package httpx

import (
	"strings"
	"testing"
)

// RouteTemplate turns a caller-controlled path into a metric label, which makes it the one
// place where untrusted input decides how many time series exist. A bug here is not a
// crash; it is a monitoring system that falls over during whatever traffic spike triggered
// it, which is exactly when the graphs were needed.

func FuzzRouteTemplate(f *testing.F) {
	for _, seed := range []string{
		"", "/", "//", "///",
		"/v1/me", "/healthz", "/v1/sync/changes",
		"/v1/sync/changes/11111111-1111-4111-a111-111111111111",
		"/v1/../etc/passwd", "/v1/%2e%2e/admin",
		"/" + strings.Repeat("a/", 5000),
		"/v1/" + strings.Repeat("x", 100000),
		"\x00", "/\x00", "/v1/me\x00",
		"/v1/ME", "/V1/me", // case, which a naive allow-list gets wrong
		"/v1/me/", "/v1/me//",
		"/01234567-89ab-cdef-0123-456789abcdef",
	} {
		f.Add(seed)
	}

	f.Fuzz(func(t *testing.T, path string) {
		template := RouteTemplate(path)

		// The whole point. Any path not in the allow-list must collapse, or a caller can
		// mint time series at will just by varying the URL.
		if !knownRoutes[template] && template != "other" {
			t.Fatalf("RouteTemplate(%q) returned %q, which is neither a known route nor 'other'",
				truncate(path), template)
		}

		// A label value the exposition format cannot carry would break the whole scrape,
		// not just one series.
		if strings.ContainsAny(template, "\n\"\\") {
			t.Fatalf("RouteTemplate(%q) returned %q, which cannot appear in a label",
				truncate(path), template)
		}

		// Bounded length. A label value is stored per series and per scrape, forever.
		if len(template) > 200 {
			t.Fatalf("RouteTemplate(%q) returned a %d character label", truncate(path), len(template))
		}
	})
}

func truncate(value string) string {
	if len(value) <= 120 {
		return value
	}
	return value[:120] + "..."
}
