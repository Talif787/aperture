# Phase 9 runbook: setup, run, and verify

Self-contained, for a fresh Cloud Shell session.

---

## What Phase 9 contains, and what it does not

**The service is unchanged.** No new endpoints, no new environment variables, no schema
change. Parts 3 to 5 below are therefore identical to Phase 8 and are included only so this
document stands alone. The work is in Part 6 and Part 7.

| Delivered | Runnable now | Where |
|---|---|---|
| Eight fuzz targets over the parsers that take untrusted input | **Yes** | `backend/internal/*/fuzz_test.go` |
| Tests for `internal/obs`, previously the only untested package | **Yes** | `backend/internal/obs/logger_test.go` |
| Seed corpora, including inputs that have broken JWT parsers elsewhere | **Yes** | same |
| Per-package coverage floors | **Yes** | `scripts/check_coverage.py` |
| Seed corpus and coverage gate in the pull request job | **Yes** | `.github/workflows/pr.yml` |
| Nightly fuzz workflow with reproducer upload | **Yes** | `.github/workflows/fuzz.yml` |
| `make fuzz`, `fuzz-one`, `fuzz-soak`, `fuzz-targets`, `coverage` | **Yes** | `Makefile` |

No new dependencies. Go's fuzzing is in the standard library.

**Expect `make fuzz` to find something.** That is why it exists, and I have no way to run
it before shipping it. Part 7.3 covers exactly what to do when it does.

---

## Part 1: verify the existing environment

```bash
cd ~ 2>/dev/null

echo "--- repository ---"
if [ -d ~/aperture/.git ]; then
  cd ~/aperture && git log --oneline -3 && git tag -l | tail -5 && git status --short | head
else
  echo "MISSING: ~/aperture is not a git repository"
fi

echo "--- toolchain ---"
for tool in git go docker python3 curl; do
  printf '%-8s %s\n' "$tool" "$(command -v $tool || echo MISSING)"
done
GOTOOLCHAIN=local go version 2>/dev/null || echo "Go 1.23 or newer is required"

echo "--- Go dependencies resolved? ---"
ls -la ~/aperture/backend/go.sum 2>/dev/null || echo "go.sum ABSENT: run make backend-deps"

echo "--- fuzz targets present? ---"
ls ~/aperture/backend/internal/*/fuzz_test.go 2>/dev/null | wc -l

echo "--- any reproducers already recorded? ---"
find ~/aperture/backend -path '*/testdata/fuzz/*' -type f 2>/dev/null | head
echo "  (a file here is a previously found failing input, kept as a regression test)"

echo "--- containers and volumes (neither survives a VM recycle) ---"
docker ps --format '{{.Names}}\t{{.Status}}' || echo "none running"
docker volume ls --format '{{.Name}}' | grep -i aperture || echo "no database volume"

echo "--- disk, which fuzzing consumes ---"
df -h ~ | tail -1
du -sh ~/.cache/go-build 2>/dev/null || true

echo "--- archive ---"
ls -la ~/aperture-phase-9.zip 2>/dev/null && md5sum ~/aperture-phase-9.zip
```

Fuzzing writes a corpus cache under `~/.cache/go-build/fuzz`, which grows with use. On a
5 GB `$HOME` that matters; Part 9 covers clearing it.

---

## Part 2: install or initialize what is missing

```bash
cd ~/aperture
source ~/.bashrc
./scripts/cloudshell_setup.sh      # idempotent
docker pull postgres:16-alpine
```

Cloud Shell ships Go 1.22, below this repository's floor of 1.23. If `go version` reports
anything older:

```bash
cd /tmp
curl -fLO https://go.dev/dl/go1.24.7.linux-amd64.tar.gz
rm -rf ~/.local/go && tar -C ~/.local -xzf go1.24.7.linux-amd64.tar.gz
grep -q 'local/go/bin' ~/.bashrc || echo 'export PATH="$HOME/.local/go/bin:$PATH"' >> ~/.bashrc
export PATH="$HOME/.local/go/bin:$PATH"
GOTOOLCHAIN=local go version
```

Apply the archive. **No files were deleted in Phase 9**, and the archive deliberately omits
`backend/go.mod` and `backend/go.sum` so it cannot revert your resolved dependencies:

```bash
cd ~
md5sum aperture-phase-9.zip
unzip -oq aperture-phase-9.zip
cd ~/aperture && chmod +x scripts/*.sh scripts/*.py
```

If `backend/go.sum` does not exist yet:

```bash
go env -w GOPROXY=direct GOSUMDB=off GOTOOLCHAIN=local   # only if the proxy is unreachable
make backend-deps
```

---

## Part 3: configure environment variables

**No new variables in this phase.** One existing variable changes what the coverage gate
measures:

| Variable | Default | Effect in Phase 9 |
|---|---|---|
| `APERTURE_TEST_DATABASE_URL` | *(empty)* | Empty makes the store tests skip, so `internal/store` coverage collapses and its floor fails |
| `FUZZ_TIME` | `10s` | Budget per fuzz target. A make variable, not an environment one: `make fuzz FUZZ_TIME=60s` |

Everything else is unchanged from Phase 8: `APERTURE_DATABASE_URL`, `APERTURE_JWKS_PATH`,
`APERTURE_TOKEN_ISSUER`, `APERTURE_TOKEN_AUDIENCE`, `APERTURE_MINIMUM_CLIENT_VERSION`,
`APERTURE_HTTP_ADDR`, `APERTURE_METRICS_ADDR`, `APERTURE_LOG_LEVEL`, `APERTURE_ENVIRONMENT`.

---

## Part 4: start the supporting services

Fuzzing needs nothing running. **Coverage does**, because the `internal/store` floor assumes
the integration tests ran.

```bash
cd ~/aperture
make backend-up                 # Postgres only
make db-migrate && make db-seed
make db-status                  # expect 4 of 4 migration file(s) recorded
```

The API service is not required for anything in this phase. Start it only if you also want
to re-run the Phase 6 and Phase 8 scenarios:

```bash
make api-down && make api-up-postgres
```

---

## Part 5: verify health

```bash
docker compose -f infra/docker-compose.yml exec -T postgres \
  pg_isready -U aperture -d aperture

make db-status
```

If the API is running:

```bash
curl -s localhost:8080/healthz
curl -s localhost:9090/metrics | head -3
```

---

## Part 6: run Phase 9

```bash
cd ~/aperture

make check                     # now includes the standard-method and module freshness checks
make backend-fmt-check
make backend-vet
make backend-test              # the seed corpus runs here, as ordinary tests
make fuzz                      # 10 seconds per target, eight targets
make coverage                  # per-package floors
```

`make backend-test` runs each fuzz target's seeds as a normal test. That is what makes a
committed reproducer a permanent regression test: it runs on every pull request, in under
a second, without fuzzing anything.

`make fuzz` is the search. Budget is per target:

```bash
make fuzz FUZZ_TIME=60s        # about eight minutes total
make fuzz-soak                 # five minutes per target, about forty
```

---

## Part 7: test scenarios

### 7.1 The eight targets and what each asserts

```bash
make fuzz-targets
```

| Target | Package | Property asserted |
|---|---|---|
| `FuzzVerify` | `authn` | No token crashes the verifier; never both an error and claims |
| `FuzzAudienceUnmarshal` | `authn` | The two-shape audience parser never panics |
| `FuzzPushDeltas` | `httpapi` | The handler always answers; a 200 always carries a result set |
| `FuzzPullChanges` | `httpapi` | Any query string produces a valid status |
| `FuzzRouteTemplate` | `httpx` | Every path collapses to a known route or `other`, bounded and label-safe |
| `FuzzDecodeCursor` | `syncapi` | A decoded cursor is never negative and round-trips exactly |
| `FuzzLabelRendering` | `metrics` | No label value produces a stray line or unbalanced quotes |
| `FuzzMetricNames` | `metrics` | Rendering completes for any metric name |

`FuzzVerify` is the one that matters most. The verifier is the only code in this service
reached by an unauthenticated caller, so a panic there is a denial of service for every
tenant at once rather than a bug report.

### 7.2 Run one target with a real budget

```bash
cd ~/aperture
make fuzz-one TARGET=FuzzVerify FUZZ_TIME=120s
```

Expected output while running:

```
fuzz: elapsed: 3s, gathering baseline coverage: 15/15 completed, now fuzzing with 4 workers
fuzz: elapsed: 30s, execs: 412033 (13724/sec), new interesting: 12 (total: 27)
```

`new interesting` counts inputs that reached code paths the corpus had not. A target that
reports zero new interesting inputs after a minute is not exploring, usually because the
seeds cannot reach past an early rejection.

The seed inputs, so you can try them by hand:

| Seed | Why it is there |
|---|---|
| `eyJhbGciOiJub25lIn0.e30.` | `alg=none`, the classic bypass some parsers accept |
| `eyJhbGciOiJIUzI1NiJ9.e30.AAAA` | Algorithm confusion: symmetric header against an asymmetric key |
| `e30.<200-deep nested JSON>.AAAA` | Where recursive descent parsers exhaust the stack |
| `"!!!.e30.AAAA"` | Non-base64 in each of the three positions |
| a genuinely valid token | So the fuzzer can reach claim validation at all |

### 7.3 When a target fails, which is the scenario that matters

Go writes the failing input to `testdata/fuzz/<Target>/<hash>` and prints it:

```
--- FAIL: FuzzVerify (0.52s)
    --- FAIL: FuzzVerify/6f2c1a9b (0.00s)
        testing.go:1591: panic: runtime error: index out of range [1] with length 1
    Failing input written to testdata/fuzz/FuzzVerify/6f2c1a9b4e...
    To re-run:
        go test -run=FuzzVerify/6f2c1a9b4e...
```

The workflow:

```bash
cd ~/aperture

# 1. See what it found
make fuzz-corpus
cat backend/internal/authn/testdata/fuzz/FuzzVerify/*

# 2. Reproduce it deterministically, no fuzzing involved
cd backend && go test ./internal/authn/ -run 'FuzzVerify/6f2c1a9b' -v; cd ..

# 3. Commit the reproducer BEFORE fixing anything
git add backend/internal/authn/testdata/
git commit -m "test(authn): record a failing input found by fuzzing"
```

Committing first is deliberate. The reproducer then runs as an ordinary test on every pull
request forever, so the fix is verified by the thing that found the bug, and a later
refactor that reintroduces it fails immediately.

**Paste the reproducer contents to me and I will fix the underlying bug.** The file format
is one value per line, prefixed by its Go type:

```
go test fuzz v1
string("\x00.\x00.\x00")
```

**Read the failure before assuming it is a product bug.** A fuzz target exercises the code
under test plus whatever the harness does to reach it, and a panic inside the harness is
reported the same way. If the message names a testing helper rather than product code, the
target is routing input through a parser that is not the subject of the test, and the fix
is in the target. Either way the reproducer is worth keeping: it becomes a regression test
for an input shape nobody had considered.

### 7.4 Watch the mechanism work, by planting a bug

Worth doing once, so the failure path is familiar before a real one arrives.

```bash
cd ~/aperture
cp backend/internal/syncapi/service.go /tmp/service.go.bak

# Accept a negative cursor, which the fuzzer asserts against.
python3 - <<'PATCH'
from pathlib import Path
p = Path('backend/internal/syncapi/service.go'); t = p.read_text()
t = t.replace("if err != nil || value < 0 {", "if err != nil {")
p.write_text(t)
print("planted: negative cursors now accepted")
PATCH

make fuzz-one TARGET=FuzzDecodeCursor FUZZ_TIME=30s
```

Expected: a failure within seconds, naming a negative input, and a reproducer written under
`backend/internal/syncapi/testdata/fuzz/FuzzDecodeCursor/`.

Restore and clean up:

```bash
cp /tmp/service.go.bak backend/internal/syncapi/service.go
rm -rf backend/internal/syncapi/testdata/fuzz/FuzzDecodeCursor
make backend-test
```

That negative cursor is not hypothetical. `DecodeCursor` feeds a `seq > $1` comparison, so a
negative value reads the change log from before its beginning, and every device that
received it would re-pull the entire history on every sync.

### 7.5 Coverage: a ratchet, not a target

```bash
cd ~/aperture
make backend-up                 # the store tests need it, or that package reads 0%
make coverage-report            # actuals, enforces nothing
make coverage-baseline          # record them as the floor
git add scripts/coverage-baseline.json
git commit -m "test: record the coverage baseline"
make coverage                   # now enforced
```

**Two mechanisms, answering different questions.**

`MINIMUMS` in `scripts/check_coverage.py` is a judgement about what a package deserves
given what it decides. There are four, all on code where thin tests are a security problem
rather than an untidiness: `authn` and `syncapi` at 70, `tenancy` and `obs` at 80.

The baseline is a measurement. It records what the suite actually covered, and the gate
refuses a decrease beyond two percentage points of tolerance, which absorbs a refactor that
deletes covered lines without changing what is tested.

**Why not one set of floors.** The first version of this file had eight percentages I chose
by judgement without running anything, and four failed on the first real run. A number
invented in advance is a statement of intent; used as a gate it only teaches people to
lower it. A measured baseline cannot be wrong about where you are, and it still refuses to
let you go backwards.

Output shape:

```
  ok   internal/authn          78.2%  (412/527 statements, min 70%, was 76.4%)
  LOW  internal/httpapi        63.1%  (250/396 statements, was 71.0%)
```

A `LOW` line naming a fall is a regression: something stopped being tested. A `LOW` line
naming a minimum is a judgement call you are being asked to make now rather than later.

To see what is uncovered:

```bash
make coverage-html
cloudshell download backend/coverage.html
```

### 7.6 Confirm the gate actually fails

```bash
cd ~/aperture
python3 - <<'PATCH'
import json, pathlib
p = pathlib.Path('scripts/coverage-baseline.json')
data = json.loads(p.read_text())
data['internal/tenancy'] = 99.9
p.write_text(json.dumps(data, indent=2) + "\n")
print("baseline raised to an unreachable 99.9%")
PATCH

make coverage || echo "  correctly failed"

git checkout scripts/coverage-baseline.json
make coverage
```

A gate nobody has watched fail is a gate nobody knows works.

### 7.7 Coverage without a database

```bash
cd ~/aperture/backend
go test -coverprofile=/tmp/nodb.out ./... > /dev/null
go tool cover -func=/tmp/nodb.out | grep 'internal/store' | tail -3
cd ..
```

Expected: `internal/store` coverage drops sharply, because the integration tests skip. That
is why its floor is 40 rather than 80: a floor must reflect what runs everywhere, or it
fails on the machine of whoever has no Postgres running and they raise the number to make
it stop.

### 7.8 Earlier phases, unchanged

```bash
make db-seed && make db-verify   # 21 isolation checks
make api-scenarios               # 24 API scenarios
make metrics-scenarios           # 17 metrics scenarios
```

Run `make db-seed` before `db-verify` after any integration test run: the store tests drop
and rebuild the schema.

---

## Part 8: verify the expected results

```bash
cd ~/aperture
make check                     && echo "1/8 static checks"
make backend-fmt-check         && echo "2/8 formatting"
make backend-vet               && echo "3/8 vet"
make backend-test-integration  && echo "4/8 go suites and seed corpora"
make fuzz                      && echo "5/8 fuzzing"
make coverage                  && echo "6/8 coverage floors"
make db-seed && make db-verify && echo "7/8 database isolation"
make api-scenarios && make metrics-scenarios && echo "8/8 scenarios"
```

| Check | Expected |
|---|---|
| `make check` | boundaries, driver isolation, module floor and freshness, alignment, lint patterns, standard methods |
| `make backend-test-integration` | `ok` for every package; fuzz seeds run as normal tests |
| `make fuzz` | eight targets, no failures, or a reproducer to send me |
| `make coverage` | every floor met |
| `make db-verify` | 21 passes |
| `make api-scenarios` | 24 passes |
| `make metrics-scenarios` | 17 passes |

---

## Part 9: troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| `go: updates to go.mod needed` | `go.mod` and `go.sum` disagree | `make backend-deps`, commit both together |
| A fuzz target fails immediately | It found a real bug, which is the point | Part 7.3. Commit the reproducer, then send it to me |
| A failure names `httptest.NewRequest` or `malformed HTTP version` | The harness broke, not the handler: `httptest.NewRequest` parses a literal request line, so a space or control character in the target fails before the code under test runs | Fixed in `FuzzPullChanges` by setting `URL.RawQuery` directly. If you see it elsewhere, the target is routing input through a parser that is not under test |
| `fuzzing requires cgo` or no workers start | Fuzzing needs a full toolchain | `GOTOOLCHAIN=local go version`; reinstall Go if it is a partial install |
| `new interesting: 0` after a minute | Seeds cannot reach past an early rejection | Expected for narrow targets like `FuzzMetricNames`. Concerning for `FuzzVerify` |
| Fuzzing fills the disk | The corpus cache grows under `~/.cache/go-build/fuzz` | `go clean -fuzzcache`, then `df -h ~` |
| `no space left on device` | The 5 GB `$HOME` | `go clean -fuzzcache -cache`, `rm -rf ios/Packages/*/.build`, `rm -rf ~/go/pkg/mod/golang.org/toolchain*` |
| `internal/store` below its floor | The integration tests skipped | `make backend-up`, then `make coverage`, which sets the variable for you |
| A package reports `no data` | It has no test files, or none ran | Check the package compiled; `go test ./internal/<name>/ -v` |
| `make coverage` fails on a floor | The floors were set by judgement, not measurement | `make coverage-report` to see actuals, then either write tests or lower the floor with a reason |
| Coverage passes locally, fails in CI | CI has a database, so different tests ran | Compare against `make coverage` with Postgres running |
| `make fuzz` reports `TARGET is required` | You ran `fuzz-one` without one | `make fuzz-targets` lists them |
| A reproducer fails after you fixed the bug | The fix is incomplete, or it fixed a different path | Re-run the single case: `go test ./internal/<pkg>/ -run 'FuzzX/<hash>' -v` |
| Everything worked yesterday, nothing today | VM recycled | Part 2, Part 4 |

### Clearing fuzz state

```bash
go clean -fuzzcache          # the search corpus; safe, it is a cache
```

Never delete `testdata/fuzz`. That is committed source: each file is a bug someone found
once, kept so it cannot come back unnoticed.

### Full teardown

```bash
cd ~/aperture
make api-down
make backend-down
docker compose -f infra/docker-compose.yml down -v
go clean -fuzzcache
rm -rf .dev backend/coverage.out backend/coverage.html
```
