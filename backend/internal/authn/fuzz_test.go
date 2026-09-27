package authn

import (
	"crypto"
	"crypto/rand"
	"crypto/rsa"
	"crypto/sha256"
	"encoding/base64"
	"encoding/json"
	"strings"
	"sync"
	"testing"
	"time"
)

// The verifier is the only code in this service that parses input from an unauthenticated
// caller, which makes it the only code where a panic is a denial of service rather than a
// bug report. Everything behind it has already been authorised.
//
// The property asserted is narrow: no input produces a panic, and the two return values
// are never both set or both empty. That is a lower bar than correctness and a far higher
// one than the fourteen inputs I thought to write by hand.

// Generated once. A key per iteration would dominate the run and the fuzzer would explore
// a fraction of the input space within the same budget.
var fuzzKey = sync.OnceValue(func() *rsa.PrivateKey {
	key, err := rsa.GenerateKey(rand.Reader, 2048)
	if err != nil {
		panic("generating fuzz key: " + err.Error())
	}
	return key
})

func fuzzVerifier() Verifier {
	return Verifier{
		Keys:     staticKeys{key: &fuzzKey().PublicKey},
		Issuer:   "https://dev.aperture.local",
		Audience: "aperture-api",
		Now:      func() time.Time { return time.Unix(1780000000, 0) },
	}
}

func FuzzVerify(f *testing.F) {
	// Seeds are the shapes a hand-written test covers, plus the ones that have broken JWT
	// parsers elsewhere. The fuzzer explores outward from these rather than from nothing.
	seeds := []string{
		"", ".", "..", "...", "a.b.c", "a.b.", ".b.c",
		strings.Repeat("A", 10000) + ".b.c",

		// alg=none, the classic bypass: a token with no signature that some parsers accept.
		base64.RawURLEncoding.EncodeToString([]byte(`{"alg":"none"}`)) + ".e30.",

		// A header claiming a symmetric algorithm against an asymmetric key.
		base64.RawURLEncoding.EncodeToString([]byte(`{"alg":"HS256"}`)) + ".e30.AAAA",

		// Deeply nested JSON, which is where recursive descent parsers exhaust the stack.
		"e30." + base64.RawURLEncoding.EncodeToString(
			[]byte(strings.Repeat(`{"a":`, 200)+"1"+strings.Repeat("}", 200))) + ".AAAA",

		// Valid base64 that is not JSON.
		base64.RawURLEncoding.EncodeToString([]byte("not json")) + ".e30.AAAA",

		// Non-base64 in each position.
		"!!!.e30.AAAA", "e30.!!!.AAAA", "e30.e30.!!!",
	}

	for _, seed := range seeds {
		f.Add(seed)
	}

	// A genuinely valid token, so the fuzzer has a path deep into the code. Without one it
	// spends the entire budget failing at the first parse and never reaches claim
	// validation at all.
	f.Add(mintFuzzToken())

	verifier := fuzzVerifier()

	f.Fuzz(func(t *testing.T, token string) {
		claims, err := verifier.Verify(token)

		// Any outcome is acceptable. Rejecting a valid token is a correctness bug other
		// tests cover; crashing on a malformed one takes the service down for every tenant.
		// What must never happen is an ambiguous result a caller cannot act on.
		if err == nil && claims == nil {
			t.Fatal("Verify returned no error and no claims")
		}
		if err != nil && claims != nil {
			t.Fatalf("Verify returned both an error and claims: %v", err)
		}
	})
}

func mintFuzzToken() string {
	header, _ := json.Marshal(map[string]any{"alg": "RS256", "typ": "JWT", "kid": "fuzz"})
	payload, _ := json.Marshal(map[string]any{
		"iss":       "https://dev.aperture.local",
		"aud":       "aperture-api",
		"sub":       "00uFUZZ0001",
		"tenant_id": "11111111-1111-4111-a111-111111111111",
		"exp":       1780000900,
		"iat":       1780000000,
	})

	signingInput := base64.RawURLEncoding.EncodeToString(header) + "." +
		base64.RawURLEncoding.EncodeToString(payload)

	digest := sha256.Sum256([]byte(signingInput))
	signature, err := rsa.SignPKCS1v15(rand.Reader, fuzzKey(), crypto.SHA256, digest[:])
	if err != nil {
		return signingInput + ".invalid"
	}

	return signingInput + "." + base64.RawURLEncoding.EncodeToString(signature)
}

func FuzzAudienceUnmarshal(f *testing.F) {
	// The audience claim accepts two shapes, so there are two parse paths, and the one no
	// real provider exercises is the one that breaks.
	for _, seed := range []string{
		`""`, `"a"`, `[]`, `["a"]`, `["a","b"]`, `null`, `0`, `{}`, `[1,2]`,
		`[[[[[[[[[["deep"]]]]]]]]]]`,
		`[` + strings.Repeat(`"x",`, 5000) + `"y"]`,
	} {
		f.Add(seed)
	}

	f.Fuzz(func(t *testing.T, raw string) {
		var audience Audience

		// No assertion beyond the absence of a panic. An unmarshaller that crashes on bad
		// input hands an unauthenticated caller a way to kill the process.
		_ = audience.UnmarshalJSON([]byte(raw))
	})
}
