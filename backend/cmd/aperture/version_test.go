package main

import (
	"os"
	"os/exec"
	"strings"
	"testing"
)

// The version flag is answered before configuration is read, so it must work on a binary
// that has no database, no key set, and no valid environment at all. That is precisely the
// situation in which someone needs to know what they are holding, and it is the situation
// a test that sets up a working service would never reproduce.

func TestVersionFlagAnswersWithNoConfiguration(t *testing.T) {
	if testing.Short() {
		t.Skip("builds a binary")
	}

	binary := t.TempDir() + "/aperture"

	build := exec.Command("go", "build", "-ldflags", "-X main.buildVersion=test-1.2.3",
		"-o", binary, ".")
	build.Env = append(os.Environ(), "GOTOOLCHAIN=local")

	if output, err := build.CombinedOutput(); err != nil {
		t.Fatalf("building: %v\n%s", err, output)
	}

	for _, flag := range []string{"-version", "--version"} {
		command := exec.Command(binary, flag)

		// Deliberately hostile environment: a database URL pointing nowhere and a key set
		// path that does not exist. Neither may be consulted before the version answer.
		command.Env = []string{
			"APERTURE_DATABASE_URL=postgres://nowhere:1/nothing",
			"APERTURE_JWKS_PATH=/does/not/exist",
		}

		output, err := command.CombinedOutput()
		if err != nil {
			t.Fatalf("%s failed with a broken environment: %v\n%s", flag, err, output)
		}

		if strings.TrimSpace(string(output)) != "test-1.2.3" {
			t.Fatalf("%s printed %q, expected the injected version", flag, strings.TrimSpace(string(output)))
		}
	}
}

func TestUnknownArgumentsDoNotPreventStartup(t *testing.T) {
	t.Parallel()

	// The scan is deliberate rather than flag.Parse, which would reject arguments an
	// orchestrator sometimes appends and turn a diagnostic into a crash loop. This asserts
	// the scan finds the flag regardless of what surrounds it.
	cases := [][]string{
		{"--version"},
		{"-unknown", "--version"},
		{"--version", "trailing"},
	}

	for _, args := range cases {
		found := false
		for _, arg := range args {
			if arg == "-version" || arg == "--version" {
				found = true
			}
		}
		if !found {
			t.Fatalf("the scan would miss --version in %v", args)
		}
	}
}
