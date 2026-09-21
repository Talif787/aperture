package httpapi

import (
	"testing"
)

func TestCompareVersions(t *testing.T) {
	t.Parallel()

	cases := []struct {
		left     string
		right    string
		expected int
		why      string
	}{
		{"2.4.0", "2.4.0", 0, "identical"},
		{"2.3.9", "2.4.0", -1, "older minor"},
		{"2.4.1", "2.4.0", 1, "newer patch"},
		{"2.4", "2.4.0", 0, "missing components count as zero"},
		{"10.0.0", "9.9.9", 1, "numeric rather than lexicographic"},
		{"2.4.0-beta", "2.4.0", 0, "a pre-release suffix compares on its numeric prefix"},
	}

	for _, testCase := range cases {
		t.Run(testCase.why, func(t *testing.T) {
			result := compareVersions(testCase.left, testCase.right)
			if sign(result) != testCase.expected {
				t.Fatalf("compareVersions(%q, %q) = %d, want %d (%s)",
					testCase.left, testCase.right, sign(result), testCase.expected, testCase.why)
			}
		})
	}
}

func TestVersionComparisonIsNotLexicographic(t *testing.T) {
	t.Parallel()

	// The bug this guards against: string comparison puts "10" before "9", so every
	// client past version 9 would be told to upgrade, and the ones still on 9 would not.
	if compareVersions("10.0.0", "9.0.0") <= 0 {
		t.Fatal("10.0.0 must be newer than 9.0.0")
	}
}

func sign(value int) int {
	switch {
	case value < 0:
		return -1
	case value > 0:
		return 1
	default:
		return 0
	}
}
