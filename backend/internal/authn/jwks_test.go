package authn

import (
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/rsa"
	"encoding/base64"
	"encoding/json"
	"errors"
	"math/big"
	"os"
	"path/filepath"
	"testing"
	"time"
)

// The key source decides which public key a signature is checked against, which makes it
// part of the authentication decision rather than a caching detail. It was the least tested
// file in the package and it is where the fixed key identifier bug lived: a regenerated key
// reusing an identifier looked like a cache hit, and every token it signed failed until the
// entry expired an hour later, with nothing logged on either side.

func rsaJWK(t *testing.T, kid string, key *rsa.PublicKey) JSONWebKey {
	t.Helper()

	return JSONWebKey{
		KeyType:   "RSA",
		KeyID:     kid,
		Algorithm: "RS256",
		Use:       "sig",
		Modulus:   base64.RawURLEncoding.EncodeToString(key.N.Bytes()),
		Exponent:  base64.RawURLEncoding.EncodeToString(big.NewInt(int64(key.E)).Bytes()),
	}
}

func newRSAKey(t *testing.T) *rsa.PrivateKey {
	t.Helper()

	key, err := rsa.GenerateKey(rand.Reader, 2048)
	if err != nil {
		t.Fatalf("generating key: %v", err)
	}
	return key
}

type countingLoader struct {
	set   *JSONWebKeySet
	err   error
	calls int
}

func (l *countingLoader) load() (*JSONWebKeySet, error) {
	l.calls++
	if l.err != nil {
		return nil, l.err
	}
	return l.set, nil
}

func TestKeyByIDReturnsAMatchingKey(t *testing.T) {
	t.Parallel()

	key := newRSAKey(t)
	loader := &countingLoader{set: &JSONWebKeySet{Keys: []JSONWebKey{rsaJWK(t, "one", &key.PublicKey)}}}

	source := &CachingKeySource{Load: loader.load, TTL: time.Hour, Now: func() time.Time {
		return time.Unix(1780000000, 0)
	}}

	found, err := source.KeyByID("one")
	if err != nil {
		t.Fatalf("KeyByID failed: %v", err)
	}
	if found.(*rsa.PublicKey).N.Cmp(key.N) != 0 {
		t.Fatal("returned a different key than the set contained")
	}
}

func TestKeyByIDCachesWithinTheTTL(t *testing.T) {
	t.Parallel()

	key := newRSAKey(t)
	loader := &countingLoader{set: &JSONWebKeySet{Keys: []JSONWebKey{rsaJWK(t, "one", &key.PublicKey)}}}

	now := time.Unix(1780000000, 0)
	source := &CachingKeySource{Load: loader.load, TTL: time.Hour, Now: func() time.Time { return now }}

	for i := 0; i < 50; i++ {
		if _, err := source.KeyByID("one"); err != nil {
			t.Fatalf("KeyByID failed: %v", err)
		}
	}

	// Fifty verifications, one fetch. Without this the service would call the provider
	// once per request, which is a self-inflicted rate limit and an outage when the
	// provider throttles it.
	if loader.calls != 1 {
		t.Fatalf("loaded the key set %d times, expected once", loader.calls)
	}
}

func TestKeyByIDRefreshesAfterTheTTL(t *testing.T) {
	t.Parallel()

	key := newRSAKey(t)
	loader := &countingLoader{set: &JSONWebKeySet{Keys: []JSONWebKey{rsaJWK(t, "one", &key.PublicKey)}}}

	now := time.Unix(1780000000, 0)
	source := &CachingKeySource{Load: loader.load, TTL: time.Hour, Now: func() time.Time { return now }}

	if _, err := source.KeyByID("one"); err != nil {
		t.Fatalf("KeyByID failed: %v", err)
	}

	now = now.Add(2 * time.Hour)

	if _, err := source.KeyByID("one"); err != nil {
		t.Fatalf("KeyByID failed after expiry: %v", err)
	}

	// A rotation must be picked up without a restart, or every rotation becomes a deploy.
	if loader.calls != 2 {
		t.Fatalf("loaded %d times, expected a refresh after the TTL", loader.calls)
	}
}

func TestAnUnknownKeyIDTriggersOneRefresh(t *testing.T) {
	t.Parallel()

	key := newRSAKey(t)
	loader := &countingLoader{set: &JSONWebKeySet{Keys: []JSONWebKey{rsaJWK(t, "one", &key.PublicKey)}}}

	now := time.Unix(1780000000, 0)
	source := &CachingKeySource{Load: loader.load, TTL: time.Hour, Now: func() time.Time { return now }}

	if _, err := source.KeyByID("one"); err != nil {
		t.Fatalf("priming failed: %v", err)
	}

	// An identifier the cache has never seen is how a rotation announces itself, so a miss
	// must reload even while the entry is fresh. This is the mechanism the fixed key
	// identifier defeated.
	_, err := source.KeyByID("two")
	if !errors.Is(err, ErrUnknownKey) {
		t.Fatalf("expected ErrUnknownKey, got %v", err)
	}
	if loader.calls != 2 {
		t.Fatalf("a cache miss did not trigger a reload: %d calls", loader.calls)
	}
}

func TestAStaleKeyIsUsedWhenTheProviderIsUnreachable(t *testing.T) {
	t.Parallel()

	key := newRSAKey(t)
	loader := &countingLoader{set: &JSONWebKeySet{Keys: []JSONWebKey{rsaJWK(t, "one", &key.PublicKey)}}}

	now := time.Unix(1780000000, 0)
	source := &CachingKeySource{Load: loader.load, TTL: time.Hour, Now: func() time.Time { return now }}

	if _, err := source.KeyByID("one"); err != nil {
		t.Fatalf("priming failed: %v", err)
	}

	loader.err = errors.New("provider unreachable")
	now = now.Add(2 * time.Hour)

	// A stale key beats no key. The signature still has to verify, so honouring a slightly
	// old key is a far smaller risk than logging out every inspector in the field because
	// the identity provider had a bad minute.
	if _, err := source.KeyByID("one"); err != nil {
		t.Fatalf("a stale key was not used during an outage: %v", err)
	}
}

func TestAnUnreachableProviderWithNoCachedKeyFails(t *testing.T) {
	t.Parallel()

	loader := &countingLoader{err: errors.New("provider unreachable")}
	source := &CachingKeySource{Load: loader.load, TTL: time.Hour}

	// Nothing cached and nothing reachable means no basis for trusting anything. Failing
	// closed is the only option; the alternative is accepting a signature unchecked.
	if _, err := source.KeyByID("one"); err == nil {
		t.Fatal("KeyByID succeeded with no key and no provider")
	}
}

func TestAKeySetWithNoUsableKeysIsRejected(t *testing.T) {
	t.Parallel()

	loader := &countingLoader{set: &JSONWebKeySet{Keys: []JSONWebKey{
		{KeyType: "oct", KeyID: "symmetric"},
	}}}
	source := &CachingKeySource{Load: loader.load, TTL: time.Hour}

	// A set containing only key types this service cannot verify is a configuration error,
	// not an empty cache. Reporting it as a missing key would send someone looking at the
	// wrong provider.
	_, err := source.KeyByID("symmetric")
	if err == nil {
		t.Fatal("an unusable key set was accepted")
	}
}

func TestECKeysAreSupported(t *testing.T) {
	t.Parallel()

	key, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		t.Fatalf("generating key: %v", err)
	}

	entry := JSONWebKey{
		KeyType:   "EC",
		KeyID:     "ec-one",
		Algorithm: "ES256",
		Curve:     "P-256",
		X:         base64.RawURLEncoding.EncodeToString(key.X.Bytes()),
		Y:         base64.RawURLEncoding.EncodeToString(key.Y.Bytes()),
	}

	loader := &countingLoader{set: &JSONWebKeySet{Keys: []JSONWebKey{entry}}}
	source := &CachingKeySource{Load: loader.load, TTL: time.Hour}

	found, err := source.KeyByID("ec-one")
	if err != nil {
		t.Fatalf("an EC key was not usable: %v", err)
	}
	if found.(*ecdsa.PublicKey).X.Cmp(key.X) != 0 {
		t.Fatal("returned a different EC key")
	}
}

func TestMalformedKeyMaterialIsRejected(t *testing.T) {
	t.Parallel()

	cases := map[string]JSONWebKey{
		"modulus is not base64":  {KeyType: "RSA", KeyID: "a", Modulus: "!!!", Exponent: "AQAB"},
		"exponent is not base64": {KeyType: "RSA", KeyID: "a", Modulus: "AQAB", Exponent: "!!!"},
		"empty modulus":          {KeyType: "RSA", KeyID: "a", Modulus: "", Exponent: "AQAB"},
		"EC without a curve":     {KeyType: "EC", KeyID: "a", X: "AQAB", Y: "AQAB"},
	}

	for name, entry := range cases {
		loader := &countingLoader{set: &JSONWebKeySet{Keys: []JSONWebKey{entry}}}
		source := &CachingKeySource{Load: loader.load, TTL: time.Hour}

		// Key material arrives over the network from a provider. Malformed material must
		// be refused rather than producing a key that verifies nothing, which would look
		// like every token being invalid.
		if _, err := source.KeyByID("a"); err == nil {
			t.Errorf("%s was accepted", name)
		}
	}
}

func TestNewFileKeySourceReadsADocument(t *testing.T) {
	t.Parallel()

	key := newRSAKey(t)
	document, err := json.Marshal(JSONWebKeySet{Keys: []JSONWebKey{rsaJWK(t, "file-one", &key.PublicKey)}})
	if err != nil {
		t.Fatalf("encoding: %v", err)
	}

	path := filepath.Join(t.TempDir(), "jwks.json")
	if err := os.WriteFile(path, document, 0o600); err != nil {
		t.Fatalf("writing: %v", err)
	}

	source := NewFileKeySource(path, time.Hour)

	if _, err := source.KeyByID("file-one"); err != nil {
		t.Fatalf("reading from disk failed: %v", err)
	}
}

func TestNewFileKeySourceReportsAMissingFile(t *testing.T) {
	t.Parallel()

	source := NewFileKeySource(filepath.Join(t.TempDir(), "absent.json"), time.Hour)

	// This is the startup failure mode: a path typo means the service cannot verify any
	// token at all, and it should say so rather than reporting every token as invalid.
	if _, err := source.KeyByID("anything"); err == nil {
		t.Fatal("a missing key set file was not reported")
	}
}

func TestNewFileKeySourceReportsMalformedJSON(t *testing.T) {
	t.Parallel()

	path := filepath.Join(t.TempDir(), "jwks.json")
	if err := os.WriteFile(path, []byte("{not json"), 0o600); err != nil {
		t.Fatalf("writing: %v", err)
	}

	source := NewFileKeySource(path, time.Hour)

	if _, err := source.KeyByID("anything"); err == nil {
		t.Fatal("a malformed key set file was not reported")
	}
}

func TestConcurrentCallersTriggerOneLoad(t *testing.T) {
	key := newRSAKey(t)
	loader := &countingLoader{set: &JSONWebKeySet{Keys: []JSONWebKey{rsaJWK(t, "one", &key.PublicKey)}}}
	source := &CachingKeySource{Load: loader.load, TTL: time.Hour}

	done := make(chan struct{})
	for i := 0; i < 20; i++ {
		go func() {
			defer func() { done <- struct{}{} }()
			_, _ = source.KeyByID("one")
		}()
	}
	for i := 0; i < 20; i++ {
		<-done
	}

	// Twenty tokens arriving together after a restart must not produce twenty requests to
	// the provider. The write lock serializes them and the second caller finds the key
	// already there.
	if loader.calls != 1 {
		t.Fatalf("concurrent callers caused %d loads, expected 1", loader.calls)
	}
}
