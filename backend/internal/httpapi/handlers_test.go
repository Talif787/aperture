package httpapi

import (
	"bytes"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"github.com/talif/aperture/backend/internal/metrics"

	"github.com/talif/aperture/backend/internal/syncapi"
	"github.com/talif/aperture/backend/internal/tenancy"
)

const testTenant = "11111111-1111-4111-a111-111111111111"

func newHandlers() Handlers {
	now := func() time.Time { return time.Unix(1780000000, 0).UTC() }
	return Handlers{Sync: syncapi.NewService(syncapi.NewInMemoryStore(now), now)}
}

func scopedRequest(method, target string, body []byte) *http.Request {
	var request *http.Request
	if body == nil {
		request = httptest.NewRequest(method, target, nil)
	} else {
		request = httptest.NewRequest(method, target, bytes.NewReader(body))
	}

	ctx := tenancy.WithPrincipal(request.Context(), tenancy.Principal{
		TenantID: testTenant,
		UserID:   "user-1",
		Roles:    []string{"inspector"},
	})
	return request.WithContext(ctx)
}

func TestPullReturnsAnEmptyPage(t *testing.T) {
	recorder := httptest.NewRecorder()

	newHandlers().pullChanges(recorder, scopedRequest(http.MethodGet, "/v1/sync/changes", nil))

	if recorder.Code != http.StatusOK {
		t.Fatalf("expected 200, got %d: %s", recorder.Code, recorder.Body)
	}

	// Asserted on the raw body rather than the decoded struct. A client decoding null into
	// a non-optional array crashes, and the distinction disappears once Go has decoded it.
	if !bytes.Contains(recorder.Body.Bytes(), []byte(`"changes":[]`)) {
		t.Fatalf("changes must serialize as [], got %s", recorder.Body)
	}
}

func TestPullRejectsAMalformedCursor(t *testing.T) {
	recorder := httptest.NewRecorder()

	newHandlers().pullChanges(
		recorder, scopedRequest(http.MethodGet, "/v1/sync/changes?cursor=nonsense", nil))

	if recorder.Code != http.StatusBadRequest {
		t.Fatalf("expected 400, got %d", recorder.Code)
	}
	assertErrorCode(t, recorder, "VALIDATION_FAILED")
}

func TestPullRejectsANonPositiveLimit(t *testing.T) {
	recorder := httptest.NewRecorder()

	newHandlers().pullChanges(
		recorder, scopedRequest(http.MethodGet, "/v1/sync/changes?limit=0", nil))

	if recorder.Code != http.StatusBadRequest {
		t.Fatalf("expected 400, got %d", recorder.Code)
	}
}

func TestPushAppliesAndThenReplays(t *testing.T) {
	handlers := newHandlers()
	body := []byte(`{"operations":[{
		"operation_id":"op-1","entity_type":"finding","entity_id":"f-1","kind":"create",
		"dirty_fields":["note"],"base_version":0,"hlc":"hlc-1","payload":{"note":"first"}
	}]}`)

	first := httptest.NewRecorder()
	handlers.pushDeltas(first, scopedRequest(http.MethodPost, "/v1/sync/deltas", body))

	second := httptest.NewRecorder()
	handlers.pushDeltas(second, scopedRequest(http.MethodPost, "/v1/sync/deltas", body))

	if statusOf(t, first) != syncapi.StatusApplied {
		t.Fatalf("expected applied, got %s", first.Body)
	}
	if statusOf(t, second) != syncapi.StatusReplayed {
		t.Fatalf("expected replayed, got %s", second.Body)
	}
}

func TestPushRejectsUnknownFields(t *testing.T) {
	recorder := httptest.NewRecorder()
	body := []byte(`{"operations":[{"operation_id":"op-1","entity_type":"finding",
		"entity_id":"f-1","kind":"create","dirty_fields":["note"],"hlc":"h",
		"surprise":"value"}]}`)

	newHandlers().pushDeltas(recorder, scopedRequest(http.MethodPost, "/v1/sync/deltas", body))

	// A client sending a field the server does not understand believes something is being
	// recorded that is not. Silently discarding it is how a protocol drifts unnoticed.
	if recorder.Code != http.StatusBadRequest {
		t.Fatalf("expected 400 for an unknown field, got %d: %s", recorder.Code, recorder.Body)
	}
}

func TestPushRejectsAnEmptyBatch(t *testing.T) {
	recorder := httptest.NewRecorder()

	newHandlers().pushDeltas(
		recorder, scopedRequest(http.MethodPost, "/v1/sync/deltas", []byte(`{"operations":[]}`)))

	if recorder.Code != http.StatusBadRequest {
		t.Fatalf("expected 400, got %d", recorder.Code)
	}
}

func TestAnUnscopedRequestIsRefused(t *testing.T) {
	recorder := httptest.NewRecorder()
	request := httptest.NewRequest(http.MethodGet, "/v1/sync/changes", nil)

	newHandlers().pullChanges(recorder, request)

	// Unreachable behind the middleware, and asserted anyway: an unscoped request reaching
	// the store is the one failure that could cross a tenant boundary, so it must fail
	// loudly rather than return an empty page that looks like missing data.
	if recorder.Code != http.StatusUnauthorized {
		t.Fatalf("expected 401, got %d: %s", recorder.Code, recorder.Body)
	}
}

func TestWhoamiReflectsTheVerifiedPrincipal(t *testing.T) {
	recorder := httptest.NewRecorder()

	newHandlers().whoami(recorder, scopedRequest(http.MethodGet, "/v1/me", nil))

	var body struct {
		TenantID string   `json:"tenant_id"`
		UserID   string   `json:"user_id"`
		Roles    []string `json:"roles"`
	}
	if err := json.NewDecoder(recorder.Body).Decode(&body); err != nil {
		t.Fatalf("decoding: %v", err)
	}
	if body.TenantID != testTenant || body.UserID != "user-1" {
		t.Fatalf("unexpected principal: %+v", body)
	}
}

func TestErrorEnvelopeShape(t *testing.T) {
	recorder := httptest.NewRecorder()
	request := scopedRequest(http.MethodGet, "/v1/sync/changes?cursor=bad", nil)

	newHandlers().pullChanges(recorder, request)

	var envelope struct {
		Error struct {
			Code       string `json:"code"`
			HTTPStatus int    `json:"http_status"`
			Retryable  bool   `json:"retryable"`
		} `json:"error"`
	}
	if err := json.NewDecoder(recorder.Body).Decode(&envelope); err != nil {
		t.Fatalf("body is not the error envelope: %v", err)
	}

	// Every failure in the service uses this shape. A client that must branch on response
	// format to discover what went wrong will eventually branch wrongly.
	if envelope.Error.Code == "" || envelope.Error.HTTPStatus != 400 {
		t.Fatalf("unexpected envelope: %+v", envelope.Error)
	}
	if envelope.Error.Retryable {
		t.Fatal("a validation failure must not be advertised as retryable")
	}
}

func TestBearerTokenParsing(t *testing.T) {
	t.Parallel()

	cases := map[string]struct {
		header string
		token  string
		ok     bool
	}{
		"standard":         {"Bearer abc.def.ghi", "abc.def.ghi", true},
		"lowercase scheme": {"bearer abc.def.ghi", "abc.def.ghi", true},
		"missing":          {"", "", false},
		"wrong scheme":     {"Basic abc", "", false},
		"scheme only":      {"Bearer ", "", false},
	}

	for name, testCase := range cases {
		t.Run(name, func(t *testing.T) {
			request := httptest.NewRequest(http.MethodGet, "/", nil)
			if testCase.header != "" {
				request.Header.Set("Authorization", testCase.header)
			}

			token, ok := bearerToken(request)
			if ok != testCase.ok || token != testCase.token {
				t.Fatalf("got (%q, %v), want (%q, %v)", token, ok, testCase.token, testCase.ok)
			}
		})
	}
}

func statusOf(t *testing.T, recorder *httptest.ResponseRecorder) string {
	t.Helper()

	var response syncapi.PushResponse
	if err := json.NewDecoder(recorder.Body).Decode(&response); err != nil {
		t.Fatalf("decoding push response: %v", err)
	}
	if len(response.Results) != 1 {
		t.Fatalf("expected one result, got %d", len(response.Results))
	}
	return response.Results[0].Status
}

func assertErrorCode(t *testing.T, recorder *httptest.ResponseRecorder, code string) {
	t.Helper()

	var envelope struct {
		Error struct {
			Code string `json:"code"`
		} `json:"error"`
	}
	if err := json.NewDecoder(recorder.Body).Decode(&envelope); err != nil {
		t.Fatalf("decoding envelope: %v", err)
	}
	if envelope.Error.Code != code {
		t.Fatalf("expected code %q, got %q", code, envelope.Error.Code)
	}
}

func TestPushRecordsEachOutcome(t *testing.T) {
	registry := metrics.NewRegistry()
	handlers := newHandlers()
	handlers.Metrics = metrics.NewRecorder(registry)

	body := []byte(`{"operations":[
	  {"operation_id":"m-1","entity_type":"finding","entity_id":"f-m1","kind":"create",
	   "dirty_fields":["note"],"base_version":0,"hlc":"h","payload":{"note":"a"}},
	  {"operation_id":"m-2","entity_type":"finding","entity_id":"f-m2","kind":"nonsense",
	   "dirty_fields":["note"],"hlc":"h"}
	]}`)

	handlers.pushDeltas(httptest.NewRecorder(), scopedRequest(http.MethodPost, "/v1/sync/deltas", body))

	var builder strings.Builder
	if err := registry.Render(&builder); err != nil {
		t.Fatalf("rendering: %v", err)
	}
	output := builder.String()

	// Every push returns 200 whatever happened inside it, because each operation carries
	// its own status. Without these counters a fleet whose operations all conflict looks
	// identical on a dashboard to one where everything applies cleanly.
	for _, expected := range []string{
		`aperture_sync_operations_total{status="applied"} 1`,
		`aperture_sync_operations_total{status="rejected"} 1`,
	} {
		if !strings.Contains(output, expected) {
			t.Fatalf("missing %s:\n%s", expected, output)
		}
	}
}

func TestConflictingFieldsAreCounted(t *testing.T) {
	registry := metrics.NewRegistry()
	handlers := newHandlers()
	handlers.Metrics = metrics.NewRecorder(registry)

	create := []byte(`{"operations":[{"operation_id":"c-1","entity_type":"finding",
	  "entity_id":"f-c","kind":"create","dirty_fields":["measurement_value"],
	  "base_version":0,"hlc":"h","payload":{"measurement_value":"3.4"}}]}`)
	conflict := []byte(`{"operations":[{"operation_id":"c-2","entity_type":"finding",
	  "entity_id":"f-c","kind":"update","dirty_fields":["measurement_value"],
	  "base_version":0,"hlc":"h","payload":{"measurement_value":"9.9"}}]}`)

	handlers.pushDeltas(httptest.NewRecorder(), scopedRequest(http.MethodPost, "/v1/sync/deltas", create))
	handlers.pushDeltas(httptest.NewRecorder(), scopedRequest(http.MethodPost, "/v1/sync/deltas", conflict))

	var builder strings.Builder
	_ = registry.Render(&builder)

	// Labelled by field, which is bounded because field keys come from a template rather
	// than from user input. A rising count on measurement_value specifically is the signal
	// that two people are disagreeing about numbers, which is worth paging someone about
	// in a way that a generic conflict count is not.
	if !strings.Contains(builder.String(), `aperture_sync_conflicts_total{field="measurement_value"} 1`) {
		t.Fatalf("conflict was not attributed to its field:\n%s", builder.String())
	}
}

func TestHandlersWorkWithoutARecorder(t *testing.T) {
	t.Parallel()

	// Nil is a valid recorder. A test should not have to construct a registry to exercise
	// a handler, and a service should not fail because observability is unconfigured.
	handlers := newHandlers()
	response := httptest.NewRecorder()

	handlers.pullChanges(response, scopedRequest(http.MethodGet, "/v1/sync/changes", nil))

	if response.Code != http.StatusOK {
		t.Fatalf("expected 200, got %d", response.Code)
	}
}
