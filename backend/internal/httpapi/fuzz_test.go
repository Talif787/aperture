package httpapi

import (
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
)

// The push endpoint is fuzzed through the handler rather than through a decode function
// extracted for the purpose.
//
// The boundary that matters is the one a device actually reaches, and it includes
// DisallowUnknownFields, the body limit, and the validation that runs after decoding.
// Extracting a decoder to make the test tidier would have tested a path no request takes.

func FuzzPushDeltas(f *testing.F) {
	seeds := []string{
		`{}`,
		`{"operations":[]}`,
		`{"operations":null}`,
		`{"operations":[{}]}`,
		`{"operations":[{"operation_id":"a","entity_type":"finding","entity_id":"b",` +
			`"kind":"create","dirty_fields":["note"],"base_version":0,"hlc":"h"}]}`,

		// Numeric edges. A base version that overflows or goes negative would compare
		// wrongly against a stored version, and the comparison decides whether an edit
		// silently overwrites someone else's work.
		`{"operations":[{"base_version":-1}]}`,
		`{"operations":[{"base_version":9223372036854775808}]}`,
		`{"operations":[{"base_version":1e309}]}`,

		// Size. The limit is enforced by MaxBytesReader, which only works if the decoder
		// reads through it rather than buffering first.
		`{"operations":[{"dirty_fields":["` + strings.Repeat("x", 100000) + `"]}]}`,

		// Shape confusion.
		`{"unknown":1}`,
		`{"operations":{"not":"an array"}}`,
		`{"operations":[[]]}`,
		strings.Repeat(`{"operations":[{"payload":`, 100) + `1` + strings.Repeat(`}]}`, 100),

		// Not JSON at all.
		"", "null", "0", `"string"`, "[]", "{", "\x00", "\xff\xfe",
	}

	for _, seed := range seeds {
		f.Add(seed)
	}

	handlers := newHandlers()

	f.Fuzz(func(t *testing.T, body string) {
		response := httptest.NewRecorder()

		// The assertion is that the handler answers. A panic here is reachable by any
		// device on the network before authentication has narrowed anything, and it takes
		// the process down for every tenant at once.
		handlers.pushDeltas(response, scopedRequest(http.MethodPost, "/v1/sync/deltas", []byte(body)))

		if response.Code < 200 || response.Code > 599 {
			t.Fatalf("handler produced status %d for %q", response.Code, truncate(body))
		}

		// A 2xx means the server accepted the batch, so the body must be a result set the
		// client can act on. An empty 200 would leave a device unable to tell what
		// happened to work it has already deleted locally.
		if response.Code == http.StatusOK && response.Body.Len() == 0 {
			t.Fatalf("handler returned 200 with an empty body for %q", truncate(body))
		}
	})
}

func FuzzPullChanges(f *testing.F) {
	for _, seed := range []string{
		"", "cursor=", "cursor=0", "cursor=-1", "cursor=abc",
		"limit=0", "limit=-1", "limit=999999999", "limit=abc",
		"cursor=1&limit=2", "cursor=" + strings.Repeat("9", 400),
		"limit=1&limit=2", // repeated parameters, where parsers disagree
		"%00", "%zz", "cursor=%00",
		" ", "\t", "a b", "\x7f", // whitespace and control characters
	} {
		f.Add(seed)
	}

	handlers := newHandlers()

	f.Fuzz(func(t *testing.T, query string) {
		// The query is assigned to the parsed URL rather than concatenated into the target.
		//
		// httptest.NewRequest builds a literal request line and parses it, so a space or a
		// control character in the target breaks the harness before the handler is reached.
		// The first version caught that with recover and a guess about which inputs were
		// the harness's fault, which meant a real handler panic could be dismissed as a
		// harness one. Setting RawQuery directly removes the ambiguity: nothing here can
		// panic except the code under test.
		request := scopedRequest(http.MethodGet, "/v1/sync/changes", nil)
		request.URL.RawQuery = query

		response := httptest.NewRecorder()
		handlers.pullChanges(response, request)

		if response.Code < 200 || response.Code > 599 {
			t.Fatalf("handler produced status %d for %q", response.Code, truncate(query))
		}

		// A 200 must carry a body the client can page from. An empty one would leave a
		// device unable to tell whether it had reached the end or lost its place.
		if response.Code == http.StatusOK && response.Body.Len() == 0 {
			t.Fatalf("handler returned 200 with an empty body for %q", truncate(query))
		}
	})
}

func truncate(value string) string {
	if len(value) <= 120 {
		return value
	}
	return value[:120] + "..."
}
