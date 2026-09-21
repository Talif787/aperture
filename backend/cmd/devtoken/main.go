// Command devtoken mints signed tokens for local development.
//
// It exists so the local stack exercises the real verification path rather than a bypass.
// The tempting shortcut is a "trust the tenant header when environment is local" mode, and
// it is a bad shortcut twice over: the authentication code then has a branch that is never
// exercised until production, and a development affordance that trusts a client-supplied
// tenant is one merge away from being the production behavior.
//
// Here the server verifies a real signature against a real key set. Only the key is local.
//
//	go run ./cmd/devtoken keygen  -out ./dev-jwks.json -key ./dev-key.pem
//	go run ./cmd/devtoken mint    -key ./dev-key.pem -tenant <uuid> -subject <sub> -roles inspector
package main

import (
	"crypto"
	"crypto/rand"
	"crypto/rsa"
	"crypto/sha256"
	"crypto/x509"
	"encoding/base64"
	"encoding/json"
	"encoding/pem"
	"flag"
	"fmt"
	"math/big"
	"os"
	"strings"
	"time"
)

// keyID derives a key identifier from the key itself, per RFC 7638.
//
// A fixed identifier was the original mistake, and it produced a failure with no useful
// symptom: regenerating the key gave a different key under the same name, a verifier that
// had already cached the old one saw a cache hit, and every freshly minted token failed
// its signature check until the cache expired an hour later. Nothing looked wrong on
// either side.
//
// A thumbprint makes rotation visible to any cache: a new key has a new identifier, the
// lookup misses, and the key set is reloaded. This is also what real providers do, and for
// the same reason.
func keyID(key *rsa.PublicKey) string {
	// RFC 7638 requires the exact members, no whitespace, lexicographic order.
	canonical := fmt.Sprintf(`{"e":%q,"kty":"RSA","n":%q}`,
		base64.RawURLEncoding.EncodeToString(big.NewInt(int64(key.E)).Bytes()),
		base64.RawURLEncoding.EncodeToString(key.N.Bytes()),
	)
	digest := sha256.Sum256([]byte(canonical))
	return base64.RawURLEncoding.EncodeToString(digest[:])
}

func main() {
	if len(os.Args) < 2 {
		usage()
		os.Exit(2)
	}

	var err error
	switch os.Args[1] {
	case "keygen":
		err = keygen(os.Args[2:])
	case "mint":
		err = mint(os.Args[2:])
	default:
		usage()
		os.Exit(2)
	}

	if err != nil {
		fmt.Fprintf(os.Stderr, "devtoken: %v\n", err)
		os.Exit(1)
	}
}

func usage() {
	fmt.Fprint(os.Stderr, `devtoken mints signed tokens for local development.

  keygen -key <path> -out <jwks path>
      Generate an RSA key and the matching JWKS document.

  mint -key <path> -tenant <uuid> -subject <sub> [-roles a,b] [-ttl 15m]
      Print a signed token.

Development only. The server verifies these exactly as it verifies a tenant
provider's tokens; only the key is local.
`)
}

func keygen(args []string) error {
	flags := flag.NewFlagSet("keygen", flag.ExitOnError)
	keyPath := flags.String("key", "dev-key.pem", "where to write the private key")
	jwksPath := flags.String("out", "dev-jwks.json", "where to write the key set")
	if err := flags.Parse(args); err != nil {
		return err
	}

	key, err := rsa.GenerateKey(rand.Reader, 2048)
	if err != nil {
		return fmt.Errorf("generating key: %w", err)
	}

	// 0600. A development key that signs tokens the local service accepts is still a
	// credential, and a world-readable one in a shared environment is a real finding.
	encoded := pem.EncodeToMemory(&pem.Block{
		Type:  "RSA PRIVATE KEY",
		Bytes: x509.MarshalPKCS1PrivateKey(key),
	})
	if err := os.WriteFile(*keyPath, encoded, 0o600); err != nil {
		return fmt.Errorf("writing key: %w", err)
	}

	set := map[string]any{
		"keys": []map[string]string{{
			"kty": "RSA",
			"kid": keyID(&key.PublicKey),
			"use": "sig",
			"alg": "RS256",
			"n":   base64.RawURLEncoding.EncodeToString(key.N.Bytes()),
			"e":   base64.RawURLEncoding.EncodeToString(big.NewInt(int64(key.E)).Bytes()),
		}},
	}

	document, err := json.MarshalIndent(set, "", "  ")
	if err != nil {
		return err
	}
	if err := os.WriteFile(*jwksPath, document, 0o644); err != nil {
		return fmt.Errorf("writing key set: %w", err)
	}

	fmt.Printf("wrote %s and %s\n", *keyPath, *jwksPath)
	fmt.Printf("key id %s\n", keyID(&key.PublicKey))
	return nil
}

func mint(args []string) error {
	flags := flag.NewFlagSet("mint", flag.ExitOnError)
	keyPath := flags.String("key", "dev-key.pem", "private key to sign with")
	issuer := flags.String("issuer", "https://dev.aperture.local", "iss claim")
	audience := flags.String("audience", "aperture-api", "aud claim")
	tenant := flags.String("tenant", "", "tenant_id claim (required)")
	subject := flags.String("subject", "", "sub claim (required)")
	roles := flags.String("roles", "inspector", "comma-separated roles")
	ttl := flags.Duration("ttl", 15*time.Minute, "token lifetime")
	if err := flags.Parse(args); err != nil {
		return err
	}

	if *tenant == "" || *subject == "" {
		return fmt.Errorf("-tenant and -subject are required")
	}

	key, err := loadKey(*keyPath)
	if err != nil {
		return err
	}

	now := time.Now()
	header := map[string]any{"alg": "RS256", "typ": "JWT", "kid": keyID(&key.PublicKey)}
	claims := map[string]any{
		"iss":       *issuer,
		"sub":       *subject,
		"aud":       *audience,
		"iat":       now.Unix(),
		"nbf":       now.Add(-time.Minute).Unix(),
		"exp":       now.Add(*ttl).Unix(),
		"tenant_id": *tenant,
		"roles":     strings.Split(*roles, ","),
	}

	token, err := sign(key, header, claims)
	if err != nil {
		return err
	}

	fmt.Println(token)
	return nil
}

func loadKey(path string) (*rsa.PrivateKey, error) {
	data, err := os.ReadFile(path)
	if err != nil {
		return nil, fmt.Errorf("reading key: %w (run 'devtoken keygen' first)", err)
	}

	block, _ := pem.Decode(data)
	if block == nil {
		return nil, fmt.Errorf("key file is not PEM")
	}

	return x509.ParsePKCS1PrivateKey(block.Bytes)
}

func sign(key *rsa.PrivateKey, header, claims map[string]any) (string, error) {
	encode := func(value any) (string, error) {
		data, err := json.Marshal(value)
		if err != nil {
			return "", err
		}
		return base64.RawURLEncoding.EncodeToString(data), nil
	}

	encodedHeader, err := encode(header)
	if err != nil {
		return "", err
	}
	encodedClaims, err := encode(claims)
	if err != nil {
		return "", err
	}

	signingInput := encodedHeader + "." + encodedClaims
	digest := sha256.Sum256([]byte(signingInput))

	signature, err := rsa.SignPKCS1v15(rand.Reader, key, crypto.SHA256, digest[:])
	if err != nil {
		return "", err
	}

	return signingInput + "." + base64.RawURLEncoding.EncodeToString(signature), nil
}
