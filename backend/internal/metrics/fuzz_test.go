package metrics

import (
	"strings"
	"testing"
)

// A malformed line does not corrupt one series, it makes Prometheus reject the entire
// scrape. Every metric the process exports disappears at once, and the cause looks like a
// network problem rather than an encoding one.

func FuzzLabelRendering(f *testing.F) {
	for _, seed := range []string{
		"", "plain", `with"quote`, `with\backslash`, "with\nnewline",
		"with\ttab", "with\x00null", "unicode: 日本語", "emoji: 🙂",
		strings.Repeat("x", 100000),
		`"`, `\`, `\"`, `""`, `\\`, "\n\n\n",
	} {
		f.Add(seed)
	}

	f.Fuzz(func(t *testing.T, value string) {
		registry := NewRegistry()
		registry.Counter("fuzz_total", "Fuzz.", Labels{"value": value}, 1)

		var builder strings.Builder
		if err := registry.Render(&builder); err != nil {
			t.Fatalf("rendering failed: %v", err)
		}

		output := builder.String()

		for _, line := range strings.Split(output, "\n") {
			if line == "" || strings.HasPrefix(line, "#") {
				continue
			}

			// Every sample is one line. An unescaped newline in a label splits it in two,
			// and the second half is garbage that fails the parse for everything after it.
			if !strings.HasPrefix(line, "fuzz_total") {
				t.Fatalf("a label value produced a stray line: %q", truncateValue(line))
			}

			// Quotes must be balanced once escaping is accounted for. An odd count means
			// the parser reads the rest of the line as part of the label.
			if unescapedQuotes(line)%2 != 0 {
				t.Fatalf("unbalanced quotes in %q", truncateValue(line))
			}
		}
	})
}

// unescapedQuotes counts quotes that are not preceded by an escaping backslash.
func unescapedQuotes(line string) int {
	count := 0
	escaped := false

	for _, character := range line {
		switch {
		case escaped:
			escaped = false
		case character == '\\':
			escaped = true
		case character == '"':
			count++
		}
	}

	return count
}

func FuzzMetricNames(f *testing.F) {
	for _, seed := range []string{
		"", "valid_total", "with space", "with\nnewline", `with"quote`,
		"1_starts_with_digit", strings.Repeat("n", 10000),
	} {
		f.Add(seed)
	}

	f.Fuzz(func(t *testing.T, name string) {
		registry := NewRegistry()
		registry.Counter(name, "Help.", nil, 1)

		var builder strings.Builder

		// The assertion is only that rendering completes. Metric names come from the code,
		// not from input, so an invalid one is a programming error rather than an attack
		// surface; what must not happen is a panic that takes the scrape down with it.
		if err := registry.Render(&builder); err != nil {
			t.Fatalf("rendering failed for name %q: %v", truncateValue(name), err)
		}
	})
}

func truncateValue(value string) string {
	if len(value) <= 120 {
		return value
	}
	return value[:120] + "..."
}
