// Package authn validates access tokens issued by a tenant's identity provider.
//
// Validation happens here rather than at the gateway for one reason: the gateway can prove
// a token is genuine, but it cannot decide what the token may do. Splitting authentication
// from authorization across two systems with different review processes and deployment
// cadences is how tenant isolation bugs are born, so the gateway does the cheap signature
// check and every decision that matters happens in the service.
//
// Implemented against the standard library. A JWT is a signed, base64url-encoded JSON
// structure, and verifying one is signature verification plus claim comparison. The
// dependency this avoids is not large, but a third-party library on the authentication
// path is a supply-chain surface, and several popular ones have shipped algorithm-confusion
// vulnerabilities.
package authn

import (
	"crypto"
	"crypto/ecdsa"
	"crypto/rsa"
	"crypto/sha256"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"math/big"
	"strings"
	"time"
)

// Errors callers distinguish, because each implies different behavior.
var (
	ErrMalformed         = errors.New("authn: token is not a well-formed JWT")
	ErrUnsupportedAlg    = errors.New("authn: unsupported signing algorithm")
	ErrUnknownKey        = errors.New("authn: signing key is not in the issuer's key set")
	ErrBadSignature      = errors.New("authn: signature verification failed")
	ErrExpired           = errors.New("authn: token has expired")
	ErrNotYetValid       = errors.New("authn: token is not yet valid")
	ErrWrongIssuer       = errors.New("authn: token issuer does not match the tenant")
	ErrWrongAudience     = errors.New("authn: token audience does not include this service")
	ErrMissingSubject    = errors.New("authn: token has no subject")
	ErrMissingTenantHint = errors.New("authn: token carries no tenant claim")
)

// ClockSkew absorbs the difference between the issuer's clock and ours.
//
// Sixty seconds. Large enough that a correctly configured provider never trips it, small
// enough that it does not meaningfully extend the life of a stolen token.
const ClockSkew = 60 * time.Second

// Claims is the subset this service reads.
type Claims struct {
	Issuer    string   `json:"iss"`
	Subject   string   `json:"sub"`
	Audience  Audience `json:"aud"`
	ExpiresAt int64    `json:"exp"`
	NotBefore int64    `json:"nbf"`
	IssuedAt  int64    `json:"iat"`

	// TenantID is a private claim the provider is configured to emit.
	//
	// Read from the token and nowhere else. The X-Aperture-Tenant-Id header exists for log
	// correlation and must never influence an authorization decision, because the client is
	// attacker-controlled and a header is trivially forged.
	TenantID string   `json:"tenant_id"`
	Roles    []string `json:"roles"`
}

// Audience accepts both shapes RFC 7519 permits: a string or an array of strings.
// Providers differ, and rejecting one of them produces an outage on a tenant onboarding.
type Audience []string

// UnmarshalJSON accepts both shapes RFC 7519 permits for the audience claim.
//
// Providers differ on whether a single audience is a string or a one-element array, and
// rejecting either produces an outage during a tenant onboarding rather than during
// development.
func (a *Audience) UnmarshalJSON(data []byte) error {
	var single string
	if err := json.Unmarshal(data, &single); err == nil {
		*a = Audience{single}
		return nil
	}

	var multiple []string
	if err := json.Unmarshal(data, &multiple); err != nil {
		return fmt.Errorf("aud claim is neither a string nor an array: %w", err)
	}
	*a = Audience(multiple)
	return nil
}

func (a Audience) contains(value string) bool {
	for _, candidate := range a {
		if candidate == value {
			return true
		}
	}
	return false
}

// Verifier checks tokens against a key set.
type Verifier struct {
	Keys     KeySource
	Issuer   string
	Audience string
	Now      func() time.Time
}

// KeySource supplies public keys by key identifier.
type KeySource interface {
	KeyByID(kid string) (crypto.PublicKey, error)
}

// Verify parses, verifies, and validates a token, returning its claims.
//
// Order matters and is deliberate: structure, then algorithm, then signature, then claims.
// Reading claims from an unverified token and acting on them, even to decide which key to
// use, is the mistake behind several published JWT vulnerabilities.
func (v Verifier) Verify(token string) (*Claims, error) {
	parts := strings.Split(token, ".")
	if len(parts) != 3 {
		return nil, ErrMalformed
	}

	headerBytes, err := decodeSegment(parts[0])
	if err != nil {
		return nil, ErrMalformed
	}

	var header struct {
		Algorithm string `json:"alg"`
		KeyID     string `json:"kid"`
	}
	if err := json.Unmarshal(headerBytes, &header); err != nil {
		return nil, ErrMalformed
	}

	// The algorithm comes from an allow-list, never from the token alone. Trusting the
	// header's choice is what permits algorithm confusion, where an attacker swaps RS256
	// for HS256 and signs with the public key as if it were a shared secret.
	if header.Algorithm != "RS256" && header.Algorithm != "ES256" {
		return nil, ErrUnsupportedAlg
	}

	key, err := v.Keys.KeyByID(header.KeyID)
	if err != nil {
		return nil, ErrUnknownKey
	}

	signature, err := decodeSegment(parts[2])
	if err != nil {
		return nil, ErrMalformed
	}

	signed := parts[0] + "." + parts[1]
	if err := verifySignature(header.Algorithm, key, signed, signature); err != nil {
		return nil, err
	}

	claimBytes, err := decodeSegment(parts[1])
	if err != nil {
		return nil, ErrMalformed
	}

	var claims Claims
	if err := json.Unmarshal(claimBytes, &claims); err != nil {
		return nil, ErrMalformed
	}

	if err := v.validate(&claims); err != nil {
		return nil, err
	}

	return &claims, nil
}

func (v Verifier) validate(claims *Claims) error {
	now := time.Now()
	if v.Now != nil {
		now = v.Now()
	}

	if claims.Issuer != v.Issuer {
		return ErrWrongIssuer
	}
	if v.Audience != "" && !claims.Audience.contains(v.Audience) {
		return ErrWrongAudience
	}
	if claims.Subject == "" {
		return ErrMissingSubject
	}
	if claims.TenantID == "" {
		return ErrMissingTenantHint
	}
	if claims.ExpiresAt != 0 && now.After(time.Unix(claims.ExpiresAt, 0).Add(ClockSkew)) {
		return ErrExpired
	}
	if claims.NotBefore != 0 && now.Before(time.Unix(claims.NotBefore, 0).Add(-ClockSkew)) {
		return ErrNotYetValid
	}

	return nil
}

func verifySignature(algorithm string, key crypto.PublicKey, signed string, signature []byte) error {
	digest := sha256.Sum256([]byte(signed))

	switch algorithm {
	case "RS256":
		publicKey, ok := key.(*rsa.PublicKey)
		if !ok {
			return ErrUnsupportedAlg
		}
		if err := rsa.VerifyPKCS1v15(publicKey, crypto.SHA256, digest[:], signature); err != nil {
			return ErrBadSignature
		}
		return nil

	case "ES256":
		publicKey, ok := key.(*ecdsa.PublicKey)
		if !ok {
			return ErrUnsupportedAlg
		}
		// ES256 signatures are the raw concatenation of r and s, not the ASN.1 form that
		// ecdsa.VerifyASN1 expects.
		if len(signature) != 64 {
			return ErrBadSignature
		}
		r := new(big.Int).SetBytes(signature[:32])
		s := new(big.Int).SetBytes(signature[32:])
		if !ecdsa.Verify(publicKey, digest[:], r, s) {
			return ErrBadSignature
		}
		return nil

	default:
		return ErrUnsupportedAlg
	}
}

// decodeSegment decodes base64url without padding, which is what JWT uses.
func decodeSegment(segment string) ([]byte, error) {
	return base64.RawURLEncoding.DecodeString(segment)
}
