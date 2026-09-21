// Package httpapi adapts the sync service to HTTP.
//
// Thin by design. Everything that decides an outcome lives in syncapi; this package parses,
// authenticates, and serializes. The split is what lets conflict detection be tested
// exhaustively without constructing requests.
package httpapi

import (
	"net/http"
	"strings"

	"github.com/talif/aperture/backend/internal/authn"
	"github.com/talif/aperture/backend/internal/obs"
	"github.com/talif/aperture/backend/internal/tenancy"
)

// Authenticator verifies bearer tokens and scopes the request.
type Authenticator struct {
	Verifier authn.Verifier
}

// Middleware verifies the token and attaches the principal.
//
// The tenant comes from the verified token and from nowhere else. There is an
// X-Aperture-Tenant-Id header in the logs for correlation, and it must never influence an
// authorization decision: the client is attacker-controlled and a header is trivially
// forged. Every tenant scope in this service traces back to a signature check.
func (a Authenticator) Middleware(next http.Handler) http.Handler {
	return http.HandlerFunc(func(writer http.ResponseWriter, request *http.Request) {
		token, ok := bearerToken(request)
		if !ok {
			writeError(writer, request, http.StatusUnauthorized, "UNAUTHENTICATED",
				"A bearer token is required.")
			return
		}

		claims, err := a.Verifier.Verify(token)
		if err != nil {
			// The reason is logged and not returned. Telling a caller whether a token
			// failed on signature, expiry, or audience is a probing oracle, and none of
			// those distinctions changes what a legitimate client does next.
			obs.Logger(request.Context()).Warn("token rejected", "reason", err.Error())
			writeError(writer, request, http.StatusUnauthorized, "UNAUTHENTICATED",
				"The token was not accepted.")
			return
		}

		principal := tenancy.Principal{
			TenantID: claims.TenantID,
			UserID:   claims.Subject,
			Roles:    claims.Roles,
		}

		ctx := tenancy.WithPrincipal(request.Context(), principal)
		next.ServeHTTP(writer, request.WithContext(ctx))
	})
}

func bearerToken(request *http.Request) (string, bool) {
	header := request.Header.Get("Authorization")
	if header == "" {
		return "", false
	}

	// Case-insensitive on the scheme, exact on the rest. Some clients send "bearer".
	const prefix = "bearer "
	if len(header) <= len(prefix) || !strings.EqualFold(header[:len(prefix)], prefix) {
		return "", false
	}

	token := strings.TrimSpace(header[len(prefix):])
	return token, token != ""
}

// RequireRole rejects a caller lacking a role.
func RequireRole(role string) func(http.Handler) http.Handler {
	return func(next http.Handler) http.Handler {
		return http.HandlerFunc(func(writer http.ResponseWriter, request *http.Request) {
			principal, err := tenancy.PrincipalFrom(request.Context())
			if err != nil || !principal.HasRole(role) {
				// 404 rather than 403 where the resource is tenant-scoped, so the API never
				// confirms the existence of something the caller cannot see. Here the route
				// itself is public knowledge, so 403 leaks nothing.
				writeError(writer, request, http.StatusForbidden, "FORBIDDEN",
					"This account does not hold the required role.")
				return
			}
			next.ServeHTTP(writer, request)
		})
	}
}

// MinimumClientVersion rejects clients older than the service supports.
//
// The gate exists because the sync protocol cannot be indefinitely backward compatible: a
// client that predates a conflict-resolution change can corrupt data rather than merely
// failing. It is deliberately a hard stop with a specific version in the response, so the
// app can tell the user what to do rather than showing a generic error.
func MinimumClientVersion(minimum string) func(http.Handler) http.Handler {
	return func(next http.Handler) http.Handler {
		return http.HandlerFunc(func(writer http.ResponseWriter, request *http.Request) {
			version := request.Header.Get("X-Aperture-Client-Version")

			if version != "" && compareVersions(version, minimum) < 0 {
				writeErrorWithDetails(writer, request, http.StatusUpgradeRequired,
					"CLIENT_VERSION_UNSUPPORTED",
					"This client version is no longer supported.",
					map[string]any{"minimum_version": minimum})
				return
			}

			next.ServeHTTP(writer, request)
		})
	}
}

// compareVersions compares dotted numeric versions.
//
// Returns a negative number when left is older. Missing components count as zero, so
// "2.4" and "2.4.0" compare equal rather than one being mysteriously older.
func compareVersions(left, right string) int {
	leftParts := strings.Split(left, ".")
	rightParts := strings.Split(right, ".")

	length := len(leftParts)
	if len(rightParts) > length {
		length = len(rightParts)
	}

	for i := 0; i < length; i++ {
		leftValue := versionComponent(leftParts, i)
		rightValue := versionComponent(rightParts, i)
		if leftValue != rightValue {
			if leftValue < rightValue {
				return -1
			}
			return 1
		}
	}

	return 0
}

func versionComponent(parts []string, index int) int {
	if index >= len(parts) {
		return 0
	}

	value := 0
	for _, character := range parts[index] {
		if character < '0' || character > '9' {
			// A non-numeric suffix such as "2.4.0-beta" stops the comparison at the numeric
			// prefix. Rejecting the whole version would lock out every pre-release build.
			break
		}
		value = value*10 + int(character-'0')
	}
	return value
}
