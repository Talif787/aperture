package main

import (
	"crypto/rand"
	"crypto/rsa"
	"testing"
)

func TestKeyIDChangesWithTheKey(t *testing.T) {
	first, err := rsa.GenerateKey(rand.Reader, 2048)
	if err != nil {
		t.Fatalf("generating key: %v", err)
	}
	second, err := rsa.GenerateKey(rand.Reader, 2048)
	if err != nil {
		t.Fatalf("generating key: %v", err)
	}

	// The whole point. A fixed identifier meant a regenerated key looked like a cache hit
	// to any verifier, and every token it signed failed until the entry expired.
	if keyID(&first.PublicKey) == keyID(&second.PublicKey) {
		t.Fatal("two different keys produced the same key id")
	}
}

func TestKeyIDIsStableForOneKey(t *testing.T) {
	key, err := rsa.GenerateKey(rand.Reader, 2048)
	if err != nil {
		t.Fatalf("generating key: %v", err)
	}

	// Equally important in the other direction: minting two tokens from one key must
	// produce the same identifier, or every token would force a key set reload.
	//
	// Bound to variables rather than compared inline. `f(x) != f(x)` is an expression
	// compared against itself, which the compiler is free to fold and which asserts
	// nothing about determinism.
	first := keyID(&key.PublicKey)
	second := keyID(&key.PublicKey)

	if first != second {
		t.Fatalf("key id is not deterministic: %q then %q", first, second)
	}
}

func TestKeyIDIsURLSafe(t *testing.T) {
	key, err := rsa.GenerateKey(rand.Reader, 2048)
	if err != nil {
		t.Fatalf("generating key: %v", err)
	}

	// It travels in a JWT header, which is base64url. Padding or a plus sign would be
	// re-encoded somewhere in the chain and the lookup would miss.
	id := keyID(&key.PublicKey)
	for _, character := range id {
		if character == '+' || character == '/' || character == '=' {
			t.Fatalf("key id contains a character that is not base64url safe: %q", id)
		}
	}
}
