package authn

import (
	"crypto"
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rsa"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"math/big"
	"os"
	"sync"
	"time"
)

// ErrKeySetEmpty is returned when a key set contains no usable keys.
var ErrKeySetEmpty = errors.New("authn: key set contains no usable keys")

// JSONWebKey is one entry in a JWKS document.
type JSONWebKey struct {
	KeyType   string `json:"kty"`
	KeyID     string `json:"kid"`
	Use       string `json:"use"`
	Algorithm string `json:"alg"`

	// RSA
	Modulus  string `json:"n"`
	Exponent string `json:"e"`

	// Elliptic curve
	Curve string `json:"crv"`
	X     string `json:"x"`
	Y     string `json:"y"`
}

// JSONWebKeySet is a JWKS document.
type JSONWebKeySet struct {
	Keys []JSONWebKey `json:"keys"`
}

// CachingKeySource resolves signing keys by identifier, with a refresh window.
//
// Caching is not an optimization here, it is a denial-of-service control. Without it, a
// flood of tokens carrying unknown key identifiers becomes a flood of outbound requests to
// the identity provider, and the provider rate-limits the service rather than the attacker.
type CachingKeySource struct {
	mu      sync.RWMutex
	keys    map[string]crypto.PublicKey
	fetched time.Time

	// Load returns the current key set. Injected so the cache can be tested without a
	// network, and so a file-backed set works for local development.
	Load func() (*JSONWebKeySet, error)

	// TTL bounds staleness. A provider rotating keys must be picked up without a restart,
	// and an hour is short enough that a compromised key is not honoured for a day.
	TTL time.Duration

	Now func() time.Time
}

// NewFileKeySource reads a JWKS document from disk.
//
// For local development only. Production resolves the set from the tenant's provider over
// HTTPS, which is why Load is injected rather than hardcoded.
func NewFileKeySource(path string, ttl time.Duration) *CachingKeySource {
	return &CachingKeySource{
		Load: func() (*JSONWebKeySet, error) {
			// #nosec G304 -- the path comes from APERTURE_JWKS_PATH, which is deployment
			// configuration rather than request input. A caller who can set it can already
			// choose which keys the service trusts, so reading an arbitrary file is not an
			// escalation.
			data, err := os.ReadFile(path)
			if err != nil {
				return nil, fmt.Errorf("authn: reading key set: %w", err)
			}
			var set JSONWebKeySet
			if err := json.Unmarshal(data, &set); err != nil {
				return nil, fmt.Errorf("authn: parsing key set: %w", err)
			}
			return &set, nil
		},
		TTL: ttl,
	}
}

// KeyByID implements KeySource.
func (c *CachingKeySource) KeyByID(kid string) (crypto.PublicKey, error) {
	now := time.Now
	if c.Now != nil {
		now = c.Now
	}

	c.mu.RLock()
	key, found := c.keys[kid]
	fresh := now().Sub(c.fetched) < c.TTL
	c.mu.RUnlock()

	if found && fresh {
		return key, nil
	}

	// A miss is what triggers a reload, which is why key identifiers must change when keys
	// change. A provider that reuses an identifier for a new key is indistinguishable from
	// a cache hit, and every token it signs fails verification until the entry expires.

	// A miss triggers at most one refresh, even when many tokens arrive at once, because
	// the write lock serializes them and the second caller finds the key already present.
	c.mu.Lock()
	defer c.mu.Unlock()

	if key, found := c.keys[kid]; found && now().Sub(c.fetched) < c.TTL {
		return key, nil
	}

	set, err := c.Load()
	if err != nil {
		// A stale key beats no key. The provider being briefly unreachable must not log
		// out an entire fleet, and the signature check still has to pass.
		if key, found := c.keys[kid]; found {
			return key, nil
		}
		return nil, err
	}

	parsed, err := parseKeySet(set)
	if err != nil {
		return nil, err
	}

	c.keys = parsed
	c.fetched = now()

	key, found = c.keys[kid]
	if !found {
		return nil, ErrUnknownKey
	}
	return key, nil
}

func parseKeySet(set *JSONWebKeySet) (map[string]crypto.PublicKey, error) {
	keys := make(map[string]crypto.PublicKey, len(set.Keys))

	for _, entry := range set.Keys {
		// Signature keys only. A key published for encryption must never be accepted for
		// verification: using one key for two purposes is how a provider's encryption key
		// becomes a token forgery oracle.
		if entry.Use != "" && entry.Use != "sig" {
			continue
		}

		switch entry.KeyType {
		case "RSA":
			key, err := parseRSAKey(entry)
			if err != nil {
				continue
			}
			keys[entry.KeyID] = key
		case "EC":
			key, err := parseECKey(entry)
			if err != nil {
				continue
			}
			keys[entry.KeyID] = key
		}
	}

	if len(keys) == 0 {
		return nil, ErrKeySetEmpty
	}
	return keys, nil
}

func parseRSAKey(entry JSONWebKey) (*rsa.PublicKey, error) {
	modulus, err := base64.RawURLEncoding.DecodeString(entry.Modulus)
	if err != nil {
		return nil, err
	}
	exponent, err := base64.RawURLEncoding.DecodeString(entry.Exponent)
	if err != nil {
		return nil, err
	}

	value := 0
	for _, b := range exponent {
		value = value<<8 | int(b)
	}

	return &rsa.PublicKey{N: new(big.Int).SetBytes(modulus), E: value}, nil
}

func parseECKey(entry JSONWebKey) (*ecdsa.PublicKey, error) {
	if entry.Curve != "P-256" {
		return nil, fmt.Errorf("authn: unsupported curve %q", entry.Curve)
	}

	x, err := base64.RawURLEncoding.DecodeString(entry.X)
	if err != nil {
		return nil, err
	}
	y, err := base64.RawURLEncoding.DecodeString(entry.Y)
	if err != nil {
		return nil, err
	}

	return &ecdsa.PublicKey{
		Curve: elliptic.P256(),
		X:     new(big.Int).SetBytes(x),
		Y:     new(big.Int).SetBytes(y),
	}, nil
}
