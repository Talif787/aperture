package httpx

import (
	"net/http"
	"strconv"
	"time"

	"github.com/talif/aperture/backend/internal/metrics"
	"github.com/talif/aperture/backend/internal/ratelimit"
	"github.com/talif/aperture/backend/internal/tenancy"
)

// Throttled is the status a refused request receives.
const Throttled = http.StatusTooManyRequests

// WithRateLimit refuses requests beyond a tenant's budget.
//
// Placed inside authentication, not outside. The key is the tenant from the verified token,
// and there is no tenant before the token is checked; keying on anything a caller supplies
// before then would let it pick its own bucket.
//
// The cost is that an unauthenticated flood is not limited here. That is the right place
// for it to be handled anyway: verification is cheap relative to a database round trip, and
// a limiter in front of it would key on an address, which for field devices behind a
// carrier NAT means throttling an entire crew because one handset misbehaved.
func WithRateLimit(limiter *ratelimit.Limiter, recorder *metrics.Recorder) Middleware {
	return func(next http.Handler) http.Handler {
		return http.HandlerFunc(func(writer http.ResponseWriter, request *http.Request) {
			principal, err := tenancy.PrincipalFrom(request.Context())
			if err != nil {
				// No verified tenant means this middleware is mounted in the wrong place.
				// Passing the request through is correct rather than refusing it: the
				// handler behind will reject an unscoped request itself, and failing
				// closed here would turn a wiring mistake into an outage.
				next.ServeHTTP(writer, request)
				return
			}

			allowed, wait := limiter.Allow(principal.TenantID)
			if allowed {
				next.ServeHTTP(writer, request)
				return
			}

			if recorder != nil {
				// Counted without a tenant label. Labelling by tenant is exactly the
				// unbounded cardinality this codebase enforces against elsewhere, and a
				// throttling counter is the last place to make that mistake: it rises
				// fastest when the system is already under strain.
				recorder.RequestThrottled(RouteTemplate(request.URL.Path))
			}

			// Retry-After in seconds, rounded up, minimum one. RFC 9110 has no sub-second
			// form, and rounding down would advertise a moment that is still too early.
			seconds := int(wait.Seconds())
			if wait > time.Duration(seconds)*time.Second {
				seconds++
			}
			if seconds < 1 {
				seconds = 1
			}

			writer.Header().Set("Retry-After", strconv.Itoa(seconds))
			writeThrottled(writer, request, seconds)
		})
	}
}
