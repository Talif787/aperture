package syncapi

import (
	"strings"
	"testing"
)

// Cursors and the push payload both arrive from a device that may be running an old build,
// a corrupted one, or nothing of ours at all. Both are parsed before any authorisation
// decision has narrowed what the caller can reach.

func FuzzDecodeCursor(f *testing.F) {
	for _, seed := range []string{
		"", "0", "1", "-1", "+1", " 1", "1 ", "01",
		"9223372036854775807",  // max int64
		"9223372036854775808",  // one past it
		"-9223372036854775808", // min int64
		"18446744073709551615", // max uint64
		"0x10", "1e3", "١٢٣",   // non-ASCII digits, which some parsers accept
		strings.Repeat("9", 400),
		"\x00", "1\x00", "NaN", "Inf",
	} {
		f.Add(seed)
	}

	f.Fuzz(func(t *testing.T, cursor string) {
		value, err := DecodeCursor(cursor)

		if err != nil {
			return
		}

		// A cursor that parses must be usable. A negative one would read backwards through
		// the change log, and a caller controls this value entirely.
		if value < 0 {
			t.Fatalf("DecodeCursor(%q) returned %d, which is negative", cursor, value)
		}

		// Round-tripping must be stable. If encoding a decoded cursor produced something
		// that decodes differently, a device would drift a little further from the truth
		// on every page and nothing would report an error.
		again, err := DecodeCursor(EncodeCursor(value))
		if err != nil {
			t.Fatalf("re-decoding %d failed: %v", value, err)
		}
		if again != value {
			t.Fatalf("round trip changed %d into %d", value, again)
		}
	})
}
