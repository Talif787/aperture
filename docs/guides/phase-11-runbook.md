# Phase 11 runbook: setup, run, and verify

Self-contained, for a fresh Cloud Shell session.

---

## What Phase 11 contains

**One runtime change, and a lot of build tooling.** The service behaves identically to
Phase 10 apart from answering `-version`. Parts 3 to 5 are therefore short and are included
only so this document stands alone. The work is in Part 6 and Part 7.

| Delivered | Runnable now | Where |
|---|---|---|
| README that reflects what the project actually is | **Yes** | `README.md` |
| `-version`, answered before any configuration is read | **Yes** | `backend/cmd/aperture` |
| Reproducible release build, stripped and trimmed | **Yes** | `make build-release` |
| Determinism check, build twice and compare | **Yes** | `make build-verify` |
| Cross-machine check against a published checksum | **Yes** | `make build-compare` |
| Module manifest read from the binary | **Yes** | `make sbom` |
| Pre-tag gate | **Yes** | `make release-check` |
| Release workflow on a tag | **Not until you tag** | `.github/workflows/release.yml` |

No new dependencies.

---

## Part 1: verify the existing environment

```bash
cd ~ 2>/dev/null

echo "--- repository ---"
if [ -d ~/aperture/.git ]; then
  cd ~/aperture
  git log --oneline -3
  git tag -l | sort -V | tr '\n' ' '; echo
  git status --short | head
else
  echo "MISSING: ~/aperture is not a git repository"
fi

echo "--- tags reachable, which git describe needs ---"
git describe --tags 2>/dev/null || echo "  no tag is reachable from HEAD"

echo "--- toolchain ---"
for tool in git go docker python3 curl gh sha256sum; do
  printf '%-10s %s\n' "$tool" "$(command -v $tool || echo MISSING)"
done
GOTOOLCHAIN=local go version 2>/dev/null || echo "Go 1.23 or newer is required"

echo "--- Go dependencies resolved? ---"
ls -la ~/aperture/backend/go.sum 2>/dev/null || echo "go.sum ABSENT: run make backend-deps"

echo "--- previous build artifacts ---"
ls -la ~/aperture/dist 2>/dev/null || echo "  no dist directory yet"

echo "--- containers (only needed for the full gate) ---"
docker ps --format '{{.Names}}\t{{.Status}}' || echo "none running"

echo "--- disk ---"
df -h ~ | tail -1

echo "--- archive ---"
ls -la ~/aperture-phase-11.zip 2>/dev/null && md5sum ~/aperture-phase-11.zip
```

**`git describe` matters here in a way it has not before.** The version embedded in the
binary comes from it, and a shallow clone has no tags. If the repository was cloned with
`--depth`, fetch them:

```bash
cd ~/aperture && git fetch --tags --unshallow 2>/dev/null || git fetch --tags
```

---

## Part 2: install or initialize what is missing

```bash
cd ~/aperture
source ~/.bashrc
./scripts/cloudshell_setup.sh      # idempotent
docker pull postgres:16-alpine     # only for the full gate
```

Cloud Shell ships Go 1.22, below this repository's floor of 1.23:

```bash
cd /tmp
curl -fLO https://go.dev/dl/go1.24.7.linux-amd64.tar.gz
rm -rf ~/.local/go && tar -C ~/.local -xzf go1.24.7.linux-amd64.tar.gz
grep -q 'local/go/bin' ~/.bashrc || echo 'export PATH="$HOME/.local/go/bin:$PATH"' >> ~/.bashrc
export PATH="$HOME/.local/go/bin:$PATH"
GOTOOLCHAIN=local go version
```

**The Go minor version is now load-bearing.** Two builds from the same source produce
different bytes under different Go minor versions. CI uses 1.24, so a local build must use
1.24 to match a published checksum.

Apply the archive. **No files were deleted in Phase 11**, and it omits `backend/go.mod`,
`backend/go.sum`, and `dist/`:

```bash
cd ~
md5sum aperture-phase-11.zip
unzip -oq aperture-phase-11.zip
cd ~/aperture && chmod +x scripts/*.sh scripts/*.py
```

If `backend/go.sum` does not exist:

```bash
go env -w GOPROXY=direct GOSUMDB=off GOTOOLCHAIN=local   # only if the proxy is unreachable
make backend-deps
```

---

## Part 3: configure environment variables

**No new variables in this phase.** Two make variables affect the build:

| Variable | Default | Purpose |
|---|---|---|
| `VERSION` | derived | The exact tag if one points at `HEAD`, otherwise `<short-sha>-dev`. Overridable for a test build |
| `RELEASE_FLAGS` | see `Makefile` | `-trimpath`, `-s -w`, and the version injection |

The service's own variables are unchanged: `APERTURE_DATABASE_URL`, `APERTURE_JWKS_PATH`,
`APERTURE_TOKEN_ISSUER`, `APERTURE_TOKEN_AUDIENCE`, `APERTURE_MINIMUM_CLIENT_VERSION`,
`APERTURE_HTTP_ADDR`, `APERTURE_METRICS_ADDR`, `APERTURE_RATE_LIMIT_PER_SECOND`,
`APERTURE_RATE_LIMIT_BURST`, `APERTURE_LOG_LEVEL`, `APERTURE_ENVIRONMENT`.

---

## Part 4: start the supporting services

**Nothing needs to run for the release tooling.** `make build-release`, `build-verify`,
`sbom`, and `version` all work on a bare checkout.

The full pre-tag gate runs the test suite, and the store tests need a database:

```bash
cd ~/aperture
make backend-up
make db-migrate && make db-seed
make db-status                  # expect 4 of 4 migration file(s) recorded
```

---

## Part 5: verify health

For the build tooling, health is the toolchain rather than a service:

```bash
cd ~/aperture
GOTOOLCHAIN=local go version    # expect 1.24.x to match CI
make version                    # what a build here would embed
git describe --tags --always
```

If the database is up, the usual checks still apply:

```bash
make db-status
curl -s localhost:8080/healthz 2>/dev/null || echo "  API not running, which is fine here"
```

---

## Part 6: run Phase 11

```bash
cd ~/aperture

make check                     # 12 static checks, no toolchain needed
make backend-fmt-check
make backend-vet
make backend-test
make build-verify              # builds twice, compares bytes
make sbom                      # modules read out of the binary
make release-check             # all of the above, in the order CI runs them
```

---

## Part 7: test scenarios

### 7.1 Dummy values

| Name | Value |
|---|---|
| Test version string | `test-1.2.3` |
| Tenant A | `11111111-1111-4111-a111-111111111111` |
| Dana Reyes, inspector | subject `00uDANA0001` |
| Build output | `dist/aperture` |
| Checksum | `dist/aperture.sha256` |
| Module manifest | `dist/aperture.modules.txt` |

### 7.2 What version will this build embed

```bash
cd ~/aperture
make version
git describe --tags --exact-match 2>/dev/null || echo "(HEAD is not tagged)"
```

Expected: an exact tag such as `phase-10` when `HEAD` is tagged, otherwise something like
`62efac3-dev`.

The `-dev` suffix is deliberate. A binary built from an untagged commit must not claim to
be a release, because the first thing anyone does with a version string is look for the tag
it names.

Force one for a test:

```bash
make build-release VERSION=test-1.2.3
./dist/aperture -version
```

### 7.3 The version flag works on a broken service

This is the scenario the flag exists for.

```bash
cd ~/aperture
make build-release VERSION=test-1.2.3

env -i APERTURE_DATABASE_URL="postgres://nowhere:1/nothing" \
       APERTURE_JWKS_PATH="/does/not/exist" \
       ./dist/aperture -version
```

Expected: `test-1.2.3`, immediately, exit code zero.

A database pointing nowhere and a key set path that does not exist. The version is answered
before any of it is read, because the moment someone most needs to know what binary they
are holding is the moment it will not start.

The Go test asserts the same thing:

```bash
cd backend && GOTOOLCHAIN=local go test ./cmd/aperture/ -run TestVersionFlag -v; cd ..
```

### 7.4 Determinism

```bash
cd ~/aperture
make build-verify
```

Expected: `reproducible: both builds are byte-identical`.

**Be clear about what this proves.** Two builds on one machine, from one source tree, with
one toolchain. Go is deterministic, so this is close to free and would only fail if
something had introduced a timestamp, a path, or a map iteration into the output. It is a
regression check, not a reproducibility proof.

### 7.5 Reproducibility, the check that actually means something

Matching a build produced somewhere else is what proves the published binary came from the
published source.

```bash
cd ~/aperture

# The checksum CI published with a tag
gh release download phase-10 -p aperture.sha256 -O - 2>/dev/null | cut -d' ' -f1
```

Then build the same commit locally and compare:

```bash
git stash list                            # make sure nothing local is uncommitted
git checkout phase-10
make build-compare SHA=<the hex from above>
git checkout -                            # back to where you were
```

Expected: `match: this source produces the published binary`.

**A mismatch is informative rather than alarming.** The likely causes, in order: a different
Go minor version, uncommitted local changes, or a different commit than the tag. All three
are worth knowing. Only after ruling them out is a mismatch a real problem.

This only works once a tag has gone through the release workflow. Before then, `gh release
download` finds nothing, which is expected.

### 7.6 The module manifest

```bash
cd ~/aperture
make sbom
cat dist/aperture.modules.txt
```

Expected: the main module and every dependency compiled in, which for this service is short:

```
  github.com/talif/aperture/backend (devel)
  github.com/jackc/pgx/v5 v5.7.5
  github.com/jackc/puddle/v2 v2.2.2
  github.com/jackc/pgpassfile v1.0.0
  github.com/jackc/pgservicefile v0.0.0-...
  golang.org/x/crypto v...
  golang.org/x/sync v...
  golang.org/x/text v...
```

Read out of the binary with `go version -m`, not out of `go.mod`. A bill of materials that
describes the source rather than the artifact describes the wrong thing: `go.mod` lists what
the build was told to use, the binary records what it actually linked.

Cross-check them:

```bash
diff <(cat dist/aperture.modules.txt | awk '{print $1}' | sort | grep -v aperture) \
     <(grep -oE '^\s+[a-z].*/[^ ]+ v[0-9][^ ]*' backend/go.sum | awk '{print $1}' | sort -u | head -20) \
  || echo "  (differences here are normal: go.sum lists every module considered, the binary lists what linked)"
```

### 7.7 The pre-tag gate

```bash
cd ~/aperture
make release-check
```

Expected: every check, then `Ready to tag <version>.`

This is the same sequence CI runs on a tag, in the same order, so a failure here is a
failure you would otherwise find after publishing. The workflow re-runs it rather than
trusting the pull request gate, because a tag can point at any commit, including one that
was never gated.

### 7.8 The release workflow

It triggers on `phase-*` and `v*` tags. It cannot be tested without pushing one, which is
worth saying plainly: **this is the only part of Phase 11 I could not verify before
shipping.**

To exercise it on an existing tag without creating anything:

```bash
gh workflow run release --ref phase-10
gh run watch
```

To see what it would do on a new tag:

```bash
make release-check                        # must pass first
git tag -a phase-11 -m "Phase 11: release engineering"
git push origin phase-11
gh run watch
```

The workflow asserts the binary reports the same version as the build that produced it. A
tag whose artifact claims a different version is worth finding before publication rather
than when someone correlates a log line against it.

### 7.9 The README is accurate

The README makes specific, checkable claims. Check them:

```bash
cd ~/aperture

echo -n "Go tests claimed 131, actual: "
grep -rh "^func Test" backend --include='*_test.go' | wc -l

echo -n "fuzz targets claimed 8, actual:  "
grep -rh "^func Fuzz" backend --include='*_test.go' | wc -l

echo -n "benchmarks claimed 12, actual:   "
grep -rh "^func Benchmark" backend --include='*_test.go' | wc -l

echo -n "third-party deps claimed 1:      "
grep -c "^require" backend/go.mod

echo -n "api-scenarios claimed 24:        "
grep -c 'pass "' scripts/api_scenarios.sh

echo -n "db-verify claimed 22:            "
grep -c 'pass "' scripts/db.sh
```

These will drift as tests are added, which is the point of checking rather than trusting.
When a number is wrong, the README is wrong and should be corrected: a document that
overstates by two today overstates by twenty in six months, and a reader who checks one
number and finds it wrong stops believing the rest.

Every make target the README names:

```bash
python3 - <<'CHECK'
import re, pathlib

doc = pathlib.Path("README.md").read_text()
targets = set(re.findall(r'^([a-z][\w-]*):', pathlib.Path("Makefile").read_text(), re.MULTILINE))

# Only what appears inside code fences and backticks. Prose containing the word "make"
# ("make that scoping a property") is not an invocation, and a check that cannot tell the
# difference reports noise, which trains you to skim past the line where a real miss is.
code = "\n".join(re.findall(r'```bash\n(.*?)```', doc, re.DOTALL))
code += "\n" + "\n".join(re.findall(r'`([^`]*)`', doc))

# Shell comments too. "# make sure nothing local is uncommitted" is prose that happens to
# live inside a code block, and counting it finds `sure` as a missing target.
code = "\n".join(line.split("#")[0] for line in code.splitlines())

used = set(re.findall(r'\bmake\s+(?:-s\s+)?([a-z][\w-]*)', code))
missing = sorted(used - targets)
print(f"  {len(used)} referenced in code, missing: {missing or 'none'}")
CHECK
```

Expected: `missing: none`. An earlier version of this check matched the word "make"
anywhere in the document and reported `that` as a missing target, which is the failure mode
worth avoiding in a check you intend people to run: a false positive every time makes the
one true positive invisible.

Then the five-minute path the README opens with, which is the claim a reader will test
first:

```bash
make backend-deps && make backend-up && make db-migrate && make db-seed
make api-up-postgres && make api-scenarios && make db-verify
```

### 7.10 Earlier phases, unchanged

```bash
make api-down && make api-up-limited RPS=1000 BURST=1000
make api-scenarios && make metrics-scenarios
make api-down && make api-up-limited
make ratelimit-scenarios
make db-seed && make db-verify
make fuzz && make coverage
```

---

## Part 8: verify the expected results

```bash
cd ~/aperture
make check                     && echo "1/8 static checks"
make backend-fmt-check         && echo "2/8 formatting"
make backend-vet               && echo "3/8 vet"
make backend-test-integration  && echo "4/8 go suites"
make build-verify              && echo "5/8 deterministic build"
make sbom                      && echo "6/8 module manifest"
./dist/aperture -version       && echo "7/8 version flag"
make release-check             && echo "8/8 pre-tag gate"
```

| Check | Expected |
|---|---|
| `make check` | 12 checks, all clean |
| `make build-verify` | byte-identical |
| `make sbom` | the main module plus the pgx tree |
| `./dist/aperture -version` | the same string `make version` prints |
| `make release-check` | `Ready to tag <version>.` |

---

## Part 9: troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| `make version` prints `unknown-dev` | Not a git repository, or no commits | Run from `~/aperture`; check `git log -1` |
| The version is `<sha>-dev` on a tagged commit | The tag is not reachable, often a shallow clone | `git fetch --tags`; confirm with `git describe --tags --exact-match` |
| `build-release` fails with "the binary reports X, expected Y" | The ldflags path changed, or `VERSION` was overridden inconsistently | Rebuild with an explicit `make build-release VERSION=...` |
| `build-verify` reports the builds differ | Something nondeterministic entered the build | Check for an embedded timestamp or path; `go version -m dist/aperture` shows the flags used |
| `build-compare` mismatches | A different Go minor version, uncommitted changes, or a different commit | `go version`, `git status --short`, `git describe`. All three must match CI |
| `gh release download` finds nothing | No tag has been through the release workflow yet | Expected before the first release; run `gh workflow run release --ref <tag>` |
| `./dist/aperture -version` starts a server instead | An old binary without the flag | `make build-release` again |
| `make sbom` lists only the main module | The binary was built with a stripped module table | Confirm `-ldflags` has no `-buildmode` change; `go version -m` should list deps |
| `release-check` fails at `backend-test` | The store tests need a database | `make backend-up`, or accept the skip and run the full gate before tagging |
| `go: updates to go.mod needed` | `go.mod` and `go.sum` disagree | `make backend-deps`, commit both |
| `no space left on device` | The 5 GB `$HOME`, now also holding `dist/` | `rm -rf dist`, `go clean -fuzzcache -cache`, `rm -rf ios/Packages/*/.build` |
| Everything worked yesterday, nothing today | VM recycled | Part 2, Part 4 |

### Full teardown

```bash
cd ~/aperture
make api-down
make backend-down
docker compose -f infra/docker-compose.yml down -v
go clean -fuzzcache
rm -rf .dev dist backend/coverage.out backend/coverage.html
```
