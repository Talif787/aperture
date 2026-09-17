package authn

import (
	"crypto"
	"crypto/rand"
	"crypto/rsa"
	"crypto/sha256"
	"encoding/base64"
	"encoding/json"
	"errors"
	"testing"
	"time"
)

type staticKeys struct {
	key crypto.PublicKey
	err error
}

func (s staticKeys) KeyByID(string) (crypto.PublicKey, error) {
	return s.key, s.err
}

type fixture struct {
	private  *rsa.PrivateKey
	verifier Verifier
	now      time.Time
}

func newFixture(t *testing.T) fixture {
	t.Helper()

	private, err := rsa.GenerateKey(rand.Reader, 2048)
	if err != nil {
		t.Fatalf("generating key: %v", err)
	}

	now := time.Unix(1780000000, 0)

	return fixture{
		private: private,
		now:     now,
		verifier: Verifier{
			Keys:     staticKeys{key: &private.PublicKey},
			Issuer:   "https://carrier.example/oauth2",
			Audience: "aperture-api",
			Now:      func() time.Time { return now },
		},
	}
}

func (f fixture) sign(t *testing.T, header map[string]any, claims map[string]any) string {
	t.Helper()

	encode := func(value any) string {
		data, err := json.Marshal(value)
		if err != nil {
			t.Fatalf("marshalling: %v", err)
		}
		return base64.RawURLEncoding.EncodeToString(data)
	}

	signing := encode(header) + "." + encode(claims)
	digest := sha256.Sum256([]byte(signing))

	signature, err := rsa.SignPKCS1v15(rand.Reader, f.private, crypto.SHA256, digest[:])
	if err != nil {
		t.Fatalf("signing: %v", err)
	}

	return signing + "." + base64.RawURLEncoding.EncodeToString(signature)
}

func (f fixture) validClaims() map[string]any {
	return map[string]any{
		"iss":       "https://carrier.example/oauth2",
		"sub":       "00u1b2c3d4",
		"aud":       "aperture-api",
		"exp":       f.now.Add(15 * time.Minute).Unix(),
		"nbf":       f.now.Add(-time.Minute).Unix(),
		"iat":       f.now.Unix(),
		"tenant_id": "tnt-1",
		"roles":     []string{"inspector"},
	}
}

func validHeader() map[string]any {
	return map[string]any{"alg": "RS256", "typ": "JWT", "kid": "key-1"}
}

func TestVerifyAcceptsAWellFormedToken(t *testing.T) {
	f := newFixture(t)

	claims, err := f.verifier.Verify(f.sign(t, validHeader(), f.validClaims()))
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if claims.TenantID != "tnt-1" || claims.Subject != "00u1b2c3d4" {
		t.Fatalf("unexpected claims: %+v", claims)
	}
}

func TestVerifyRejectsATamperedPayload(t *testing.T) {
	f := newFixture(t)
	token := f.sign(t, validHeader(), f.validClaims())

	forged := map[string]any{
		"iss": "https://carrier.example/oauth2", "sub": "00u1b2c3d4", "aud": "aperture-api",
		"exp": f.now.Add(time.Hour).Unix(), "tenant_id": "tnt-VICTIM", "roles": []string{"admin"},
	}
	payload, _ := json.Marshal(forged)

	parts := splitToken(token)
	tampered := parts[0] + "." + base64.RawURLEncoding.EncodeToString(payload) + "." + parts[2]

	// The attack this defends against: swap the tenant and elevate the role, keeping the
	// original signature. Reading claims before verifying the signature is what makes it work.
	if _, err := f.verifier.Verify(tampered); !errors.Is(err, ErrBadSignature) {
		t.Fatalf("expected ErrBadSignature, got %v", err)
	}
}

func TestVerifyRejectsTheNoneAlgorithm(t *testing.T) {
	f := newFixture(t)
	header := map[string]any{"alg": "none", "typ": "JWT", "kid": "key-1"}

	data, _ := json.Marshal(f.validClaims())
	headerData, _ := json.Marshal(header)
	token := base64.RawURLEncoding.EncodeToString(headerData) + "." +
		base64.RawURLEncoding.EncodeToString(data) + "."

	// The classic JWT vulnerability. The algorithm comes from an allow-list, never from the
	// token, because the token is attacker-supplied.
	if _, err := f.verifier.Verify(token); !errors.Is(err, ErrUnsupportedAlg) && !errors.Is(err, ErrMalformed) {
		t.Fatalf("expected the none algorithm to be rejected, got %v", err)
	}
}

func TestVerifyRejectsAlgorithmConfusion(t *testing.T) {
	f := newFixture(t)
	header := map[string]any{"alg": "HS256", "typ": "JWT", "kid": "key-1"}

	// HS256 with the RSA public key as the shared secret. Accepting the header's algorithm
	// choice is what makes this forgeable, since the public key is public.
	if _, err := f.verifier.Verify(f.sign(t, header, f.validClaims())); !errors.Is(err, ErrUnsupportedAlg) {
		t.Fatalf("expected ErrUnsupportedAlg, got %v", err)
	}
}

func TestVerifyRejectsAnExpiredToken(t *testing.T) {
	f := newFixture(t)
	claims := f.validClaims()
	claims["exp"] = f.now.Add(-2 * time.Minute).Unix()

	if _, err := f.verifier.Verify(f.sign(t, validHeader(), claims)); !errors.Is(err, ErrExpired) {
		t.Fatalf("expected ErrExpired, got %v", err)
	}
}

func TestVerifyToleratesClockSkew(t *testing.T) {
	f := newFixture(t)
	claims := f.validClaims()
	claims["exp"] = f.now.Add(-30 * time.Second).Unix()

	// Thirty seconds past expiry, inside the sixty second allowance. A provider whose clock
	// runs slightly behind must not cause spurious rejections.
	if _, err := f.verifier.Verify(f.sign(t, validHeader(), claims)); err != nil {
		t.Fatalf("skew should be tolerated: %v", err)
	}
}

func TestVerifyRejectsTheWrongIssuerAndAudience(t *testing.T) {
	f := newFixture(t)

	wrongIssuer := f.validClaims()
	wrongIssuer["iss"] = "https://attacker.example/oauth2"
	if _, err := f.verifier.Verify(f.sign(t, validHeader(), wrongIssuer)); !errors.Is(err, ErrWrongIssuer) {
		t.Fatalf("expected ErrWrongIssuer, got %v", err)
	}

	wrongAudience := f.validClaims()
	wrongAudience["aud"] = "some-other-service"
	if _, err := f.verifier.Verify(f.sign(t, validHeader(), wrongAudience)); !errors.Is(err, ErrWrongAudience) {
		t.Fatalf("expected ErrWrongAudience, got %v", err)
	}
}

func TestVerifyRequiresATenantClaim(t *testing.T) {
	f := newFixture(t)
	claims := f.validClaims()
	delete(claims, "tenant_id")

	// A token with no tenant must not authenticate. The alternative is a request that
	// reaches the service with no scope, which row-level security would then fail closed on,
	// producing an empty result that looks like missing data rather than a rejected token.
	if _, err := f.verifier.Verify(f.sign(t, validHeader(), claims)); !errors.Is(err, ErrMissingTenantHint) {
		t.Fatalf("expected ErrMissingTenantHint, got %v", err)
	}
}

func TestAudienceAcceptsBothShapes(t *testing.T) {
	t.Parallel()

	var single Audience
	if err := json.Unmarshal([]byte(`"aperture-api"`), &single); err != nil {
		t.Fatalf("string audience: %v", err)
	}

	var multiple Audience
	if err := json.Unmarshal([]byte(`["aperture-api","other"]`), &multiple); err != nil {
		t.Fatalf("array audience: %v", err)
	}

	// RFC 7519 permits both, providers differ, and rejecting one produces an outage during
	// a tenant onboarding rather than during development.
	if !single.contains("aperture-api") || !multiple.contains("other") {
		t.Fatal("audience matching is wrong")
	}
}

func TestVerifyRejectsMalformedInput(t *testing.T) {
	f := newFixture(t)

	for name, token := range map[string]string{
		"empty":         "",
		"two segments":  "a.b",
		"four segments": "a.b.c.d",
		"not base64":    "!!!.!!!.!!!",
	} {
		t.Run(name, func(t *testing.T) {
			if _, err := f.verifier.Verify(token); err == nil {
				t.Fatal("expected a rejection")
			}
		})
	}
}

func TestVerifyRejectsAnUnknownKey(t *testing.T) {
	f := newFixture(t)
	f.verifier.Keys = staticKeys{err: errors.New("no such key")}

	if _, err := f.verifier.Verify(f.sign(t, validHeader(), f.validClaims())); !errors.Is(err, ErrUnknownKey) {
		t.Fatalf("expected ErrUnknownKey, got %v", err)
	}
}

func splitToken(token string) [3]string {
	var parts [3]string
	index := 0
	start := 0
	for i := 0; i < len(token) && index < 3; i++ {
		if token[i] == '.' {
			parts[index] = token[start:i]
			index++
			start = i + 1
		}
	}
	if index < 3 {
		parts[index] = token[start:]
	}
	return parts
}
