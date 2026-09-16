package httpx

import (
	"io"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

	"github.com/talif/aperture/backend/internal/obs"
)

func TestCorrelationIDIsAdoptedFromTheClient(t *testing.T) {
	t.Parallel()

	var observed string
	handler := WithCorrelationID(http.HandlerFunc(func(_ http.ResponseWriter, request *http.Request) {
		observed = obs.CorrelationID(request.Context())
	}))

	request := httptest.NewRequest(http.MethodGet, "/healthz", nil)
	request.Header.Set(CorrelationIDHeader, "device-generated-id")
	recorder := httptest.NewRecorder()

	handler.ServeHTTP(recorder, request)

	if observed != "device-generated-id" {
		t.Fatalf("expected the client identifier to be adopted, got %q", observed)
	}
	if echoed := recorder.Header().Get(CorrelationIDHeader); echoed != "device-generated-id" {
		t.Fatalf("expected the identifier echoed back, got %q", echoed)
	}
}

func TestCorrelationIDIsGeneratedWhenAbsentOrOversized(t *testing.T) {
	t.Parallel()

	cases := map[string]string{
		"absent":    "",
		"oversized": strings.Repeat("x", 65),
	}

	for name, header := range cases {
		t.Run(name, func(t *testing.T) {
			var observed string
			handler := WithCorrelationID(http.HandlerFunc(func(_ http.ResponseWriter, request *http.Request) {
				observed = obs.CorrelationID(request.Context())
			}))

			request := httptest.NewRequest(http.MethodGet, "/healthz", nil)
			if header != "" {
				request.Header.Set(CorrelationIDHeader, header)
			}

			handler.ServeHTTP(httptest.NewRecorder(), request)

			if observed == "" || observed == header {
				t.Fatalf("expected a freshly generated identifier, got %q", observed)
			}
		})
	}
}

func TestRecoveryConvertsPanicIntoFiveHundred(t *testing.T) {
	t.Parallel()

	logger := slog.New(slog.NewJSONHandler(io.Discard, nil))
	handler := WithRecovery(logger)(http.HandlerFunc(func(http.ResponseWriter, *http.Request) {
		panic("boom")
	}))

	recorder := httptest.NewRecorder()
	handler.ServeHTTP(recorder, httptest.NewRequest(http.MethodGet, "/", nil))

	if recorder.Code != http.StatusInternalServerError {
		t.Fatalf("expected 500, got %d", recorder.Code)
	}
}

func TestMaxBodySizeRejectsOversizedRequests(t *testing.T) {
	t.Parallel()

	handler := WithMaxBodySize(16)(http.HandlerFunc(func(writer http.ResponseWriter, request *http.Request) {
		if _, err := io.ReadAll(request.Body); err != nil {
			writer.WriteHeader(http.StatusRequestEntityTooLarge)
		}
	}))

	request := httptest.NewRequest(http.MethodPost, "/", strings.NewReader(strings.Repeat("a", 64)))
	recorder := httptest.NewRecorder()

	handler.ServeHTTP(recorder, request)

	if recorder.Code != http.StatusRequestEntityTooLarge {
		t.Fatalf("expected 413, got %d", recorder.Code)
	}
}

func TestChainAppliesOutermostFirst(t *testing.T) {
	t.Parallel()

	var order []string
	first := func(next http.Handler) http.Handler {
		return http.HandlerFunc(func(writer http.ResponseWriter, request *http.Request) {
			order = append(order, "first")
			next.ServeHTTP(writer, request)
		})
	}
	second := func(next http.Handler) http.Handler {
		return http.HandlerFunc(func(writer http.ResponseWriter, request *http.Request) {
			order = append(order, "second")
			next.ServeHTTP(writer, request)
		})
	}

	handler := Chain(http.HandlerFunc(func(http.ResponseWriter, *http.Request) {
		order = append(order, "handler")
	}), first, second)

	handler.ServeHTTP(httptest.NewRecorder(), httptest.NewRequest(http.MethodGet, "/", nil))

	if len(order) != 3 || order[0] != "first" || order[1] != "second" || order[2] != "handler" {
		t.Fatalf("unexpected middleware order: %v", order)
	}
}
