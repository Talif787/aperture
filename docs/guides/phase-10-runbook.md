# Phase 10 runbook: setup, run, and verify

Self-contained, for a fresh Cloud Shell session.

---

## What Phase 10 contains

| Delivered | Runnable now | Where |
|---|---|---|
| Per-tenant token buckets with bounded memory | **Yes** | `backend/internal/ratelimit` |
| Rate limit middleware, inside authentication | **Yes** | `backend/internal/httpx` |
| `429` with `Retry-After` and the standard envelope | **Yes** | `backend/internal/httpx` |
| Throttle counter, labelled by route only | **Yes** | `backend/internal/metrics` |
| Benchmarks for the hot paths | **Yes** | `backend/internal/*/bench_test.go` |
| `make bench`, `bench-one`, `bench-save` | **Yes** | `Makefile` |
| `make ratelimit-scenarios` | **Yes** | `scripts/ratelimit_scenarios.sh` |

No new dependencies. The limiter is written rather than imported, for a reason Part 7.7
covers.

**Rate limiting is off by default.** Zero means no limiter at all, which is deliberately
different from a limiter that allows nothing: the second would be an outage caused by a
default.

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

echo "--- ports ---"
curl -sf http://localhost:8080/healthz >/dev/null && echo "  8080 in use" || echo "  8080 free"
curl -sf http://localhost:9090/metrics >/dev/null && echo "  9090 in use" || echo "  9090 free"

echo "--- is the running service rate limited? ---"
grep -E "rate limiting (enabled|disabled)" ~/aperture/.dev/aperture.log 2>/dev/null | tail -1 \
  || echo "  no service log yet"

echo "--- containers and volumes (neither survives a VM recycle) ---"
docker ps --format '{{.Names}}\t{{.Status}}' || echo "none running"
docker volume ls --format '{{.Name}}' | grep -i aperture || echo "no database volume"

echo "--- disk ---"
df -h ~ | tail -1

echo "--- archive ---"
ls -la ~/aperture-phase-10.zip 2>/dev/null && md5sum ~/aperture-phase-10.zip
```

---

## Part 2: install or initialize what is missing

```bash
cd ~/aperture
source ~/.bashrc
./scripts/cloudshell_setup.sh      # idempotent
docker pull postgres:16-alpine
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

Apply the archive. **No files were deleted in Phase 10**, and it omits `backend/go.mod` and
`backend/go.sum` so it cannot revert your resolved dependencies:

```bash
cd ~
md5sum aperture-phase-10.zip
unzip -oq aperture-phase-10.zip
cd ~/aperture && chmod +x scripts/*.sh scripts/*.py
```

If `backend/go.sum` does not exist:

```bash
go env -w GOPROXY=direct GOSUMDB=off GOTOOLCHAIN=local   # only if the proxy is unreachable
make backend-deps
```

---

## Part 3: configure environment variables

Two new variables.

| Variable | Default | Purpose |
|---|---|---|
| `APERTURE_RATE_LIMIT_PER_SECOND` | `0` | **Zero disables the limiter entirely.** Sustained requests per second, per tenant |
| `APERTURE_RATE_LIMIT_BURST` | `60` | How many requests a tenant may make at once. Ignored when the rate is zero |

A malformed value falls back to the default rather than refusing to boot. That sounds
laxer than it is: the alternative means a typo in a deployment variable takes the service
down, and the fallback here is the behaviour that existed before this phase.

Everything else is unchanged: `APERTURE_DATABASE_URL`, `APERTURE_JWKS_PATH`,
`APERTURE_TOKEN_ISSUER`, `APERTURE_TOKEN_AUDIENCE`, `APERTURE_MINIMUM_CLIENT_VERSION`,
`APERTURE_HTTP_ADDR`, `APERTURE_METRICS_ADDR`, `APERTURE_LOG_LEVEL`, `APERTURE_ENVIRONMENT`.

**Choosing the numbers.** Burst absorbs a fleet reconnecting at shift end, which is the load
pattern this product actually has: fifty devices coming back into signal at once, each with
a few hours of queued work. The sustained rate is what one device needs to drain that queue
without starving the others. `make bench` gives the per-request cost to reason from.

---

## Part 4: start the services

```bash
cd ~/aperture
make backend-up                 # Postgres only
make db-migrate && make db-seed
make db-status                  # expect 4 of 4 migration file(s) recorded

make api-down
make api-up-limited             # 2 requests per second, burst of 5
```

`api-up-limited` is a convenience for the scenarios below. For other values:

```bash
make api-down
make api-up-limited RPS=10 BURST=30
```

Or the general form, which is what a deployment would set:

```bash
make api-down
make api-up DATABASE_URL="postgres://aperture_app:local-development-only@localhost:5432/aperture?sslmode=disable" \
            RATE_LIMIT_PER_SECOND=10 RATE_LIMIT_BURST=30
```

To run without limiting, which is the default:

```bash
make api-down && make api-up-postgres
```

---

## Part 5: verify service health

```bash
curl -s localhost:8080/healthz
curl -s localhost:8080/readyz
curl -s localhost:9090/metrics | head -3
```

**Confirm the limiter is actually on.** This is the check worth not skipping, because
without it every scenario in Part 7 passes or fails for the wrong reason:

```bash
grep -E "rate limiting (enabled|disabled)" ~/aperture/.dev/aperture.log | tail -1
```

You want `rate limiting enabled` with the configured rate and burst. `rate limiting
disabled` means the variable did not reach the process.

---

## Part 6: run Phase 10

```bash
cd ~/aperture

make check                     # includes the alignment, lint pattern, and selector checks
make backend-fmt-check
make backend-vet
make backend-test
make ratelimit-scenarios       # 14 assertions against the running service
make bench                     # every benchmark, one second each
```

---

## Part 7: test scenarios

### 7.1 Dummy values

| Name | Value |
|---|---|
| Tenant A, Northwind Mutual | `11111111-1111-4111-a111-111111111111` |
| Tenant B, Pacific Grid Utilities | `22222222-2222-4222-a222-222222222222` |
| Dana Reyes, inspector, tenant A | subject `00uDANA0001` |
| Marcus Obi, inspector, tenant B | subject `00uMARCUS01` |
| Rate for these scenarios | 2 per second, burst 5 |

```bash
cd ~/aperture
TOKEN_A=$(make -s api-token TENANT=11111111-1111-4111-a111-111111111111 SUBJECT=00uDANA0001)
TOKEN_B=$(make -s api-token TENANT=22222222-2222-4222-a222-222222222222 SUBJECT=00uMARCUS01)
```

### 7.2 Spend the budget

```bash
for i in $(seq 1 8); do
  printf '%d: %s\n' "$i" \
    "$(curl -s -o /dev/null -w '%{http_code}' -H "Authorization: Bearer $TOKEN_A" localhost:8080/v1/me)"
done
```

Expected: five `200`s then `429`s. The bucket starts full rather than empty, because a
device's first request after a restart is the one it has the most to send.

### 7.3 What a refusal tells the client

```bash
curl -si -H "Authorization: Bearer $TOKEN_A" localhost:8080/v1/me | head -12
```

Expected headers and body:

```
HTTP/1.1 429 Too Many Requests
Retry-After: 1
Content-Type: application/json
```

```json
{
  "error": {
    "code": "RATE_LIMITED",
    "correlation_id": "...",
    "details": {"retry_after_seconds": 1},
    "message": "Too many requests for this tenant. Retry after the advertised delay.",
    "retryable": true
  }
}
```

Three things in there are load-bearing.

`Retry-After` is at least one and rounded up. RFC 9110 has no sub-second form, so rounding
down would advertise a moment that is still too early, and a client that retries then gets
refused again.

`retryable: true` is explicit. The sync engine dead-letters permanent rejections, so a
throttle that looked permanent would make a device discard work it should simply resend.

The envelope is the same shape as every other refusal. A client that parses one shape for
validation failures and another for throttling grows two code paths, and the one it
exercises least is the one that runs during an incident.

### 7.4 Tenant isolation, which is the point of the design

```bash
# Tenant A is exhausted from 7.2. Tenant B, immediately:
curl -s -o /dev/null -w '%{http_code}\n' -H "Authorization: Bearer $TOKEN_B" localhost:8080/v1/me
```

Expected: `200`.

Keying on the tenant rather than the address is the whole design. Inspectors in the field
share a carrier NAT or a site's single uplink, so address-based limiting throttles an entire
crew because one handset misbehaved. The tenant comes from the verified token, which also
means a caller cannot escape its own limit by changing anything it controls.

### 7.5 Recovery

```bash
curl -s -o /dev/null -w 'immediately: %{http_code}\n' -H "Authorization: Bearer $TOKEN_A" localhost:8080/v1/me
sleep 3
curl -s -o /dev/null -w 'after 3s:     %{http_code}\n' -H "Authorization: Bearer $TOKEN_A" localhost:8080/v1/me
```

Expected: `429` then `200`. Tokens accrue continuously rather than on a timer, so a fleet
retrying in lockstep does not all land on the same tick and produce a thundering herd.

### 7.6 Throttling is measured, without a cardinality bug

```bash
curl -s localhost:9090/metrics | grep aperture_http_throttled_total
curl -s localhost:9090/metrics | grep -c '^aperture_http_throttled_total{'
```

Expected: a count labelled by route, a handful of series, and **no tenant label anywhere**.

```bash
curl -s localhost:9090/metrics | grep 11111111-1111 && echo "PROBLEM: tenant in a label" || echo "no tenant labels"
```

This counter rises fastest exactly when the system is under strain, which makes it the
worst possible place to blow up cardinality. Tenant identifiers are unbounded.

### 7.7 Memory is bounded

The limiter holds one bucket per tenant, and that map is the part that would leak.

```bash
cd ~/aperture/backend
GOTOOLCHAIN=local go test ./internal/ratelimit/ -run 'TestIdleKeys|TestAFullTable' -v
cd ..
```

| Test | Property |
|---|---|
| `TestIdleKeysAreEvicted` | Keys nobody is using are dropped after the idle TTL |
| `TestAFullTableStillServesANewTenant` | At the ceiling, the stalest key is evicted rather than the newcomer refused |

That second one is why this is written rather than imported. A map of limiters keyed by
tenant grows without bound, and the leak presents as a slow memory problem rather than as a
rate-limiting one. Refusing the newcomer instead would turn a memory bound into a denial of
service against a tenant that has done nothing.

### 7.8 Correctness under contention

```bash
cd ~/aperture/backend
GOTOOLCHAIN=local go test ./internal/ratelimit/ -race -run TestConcurrent -v
cd ..
```

Two hundred goroutines against a bucket of a hundred, and exactly a hundred must pass. A
limiter that is racy under contention is worthless, because contention is the only condition
it exists for.

### 7.9 A clock moving backwards

```bash
cd ~/aperture/backend
GOTOOLCHAIN=local go test ./internal/ratelimit/ -run TestClockGoingBackwards -v
cd ..
```

Virtual machines move clocks backwards on migration. A bucket that refilled on a negative
interval would loosen its limit precisely when the host is already struggling.

### 7.10 Benchmarks

```bash
cd ~/aperture
make bench
```

Expected shape:

```
BenchmarkAllowHot-4              20000000    62 ns/op     0 B/op   0 allocs/op
BenchmarkAllowContended-4         5000000   240 ns/op     0 B/op   0 allocs/op
BenchmarkRateLimitMiddleware-4    1000000  1100 ns/op   900 B/op  12 allocs/op
BenchmarkPushApply-4               500000  2400 ns/op  1200 B/op  18 allocs/op
BenchmarkRenderRealisticRegistry-4   20000 58000 ns/op 24000 B/op 300 allocs/op
```

**Those numbers are illustrative, not measured.** I have no way to run them before shipping.
What matters is the relationships, not the absolutes:

- `AllowContended` should be within a small multiple of `AllowHot`. If it is an order of
  magnitude worse, the map lock is being held for the whole operation rather than just the
  lookup.
- `AllowHot` should allocate zero per operation. A limiter that allocates per request adds
  garbage collection pressure in proportion to load, which is backwards.
- `RenderRealisticRegistry` runs on a scrape timer forever, so its cost is paid
  continuously on the same process serving traffic.

Individual benchmarks:

```bash
make bench-one NAME=BenchmarkAllowContended BENCH_TIME=5s
make bench-one NAME=BenchmarkPushReplay
```

To compare before and after a change:

```bash
make bench-save                                   # writes .dev/bench-base.txt
# ... make your change ...
make bench BENCH_COUNT=6 > /tmp/bench-new.txt
diff .dev/bench-base.txt /tmp/bench-new.txt
```

### 7.11 The limiter off

```bash
cd ~/aperture
make api-down && make api-up-postgres
grep "rate limiting disabled" .dev/aperture.log

TOKEN_A=$(make -s api-token TENANT=11111111-1111-4111-a111-111111111111 SUBJECT=00uDANA0001)
for i in $(seq 1 20); do
  curl -s -o /dev/null -w '%{http_code} ' -H "Authorization: Bearer $TOKEN_A" localhost:8080/v1/me
done; echo
```

Expected: twenty `200`s. Confirms that zero means no limiter rather than a limiter that
allows nothing.

### 7.12 Earlier phases, unchanged

```bash
make api-down && make api-up-limited RPS=1000 BURST=1000
make api-scenarios
make metrics-scenarios
make db-seed && make db-verify
```

The high limit matters: the scenario suites send requests in tight loops and would throttle
themselves against the Part 4 settings. That is the limiter working, but it makes the other
suites fail for an unrelated reason.

---

## Part 8: verify the expected results

```bash
cd ~/aperture
make check                     && echo "1/9 static checks"
make backend-fmt-check         && echo "2/9 formatting"
make backend-vet               && echo "3/9 vet"
make backend-test-integration  && echo "4/9 go suites"
make fuzz                      && echo "5/9 fuzzing"
make coverage                  && echo "6/9 coverage ratchet"
make db-seed && make db-verify && echo "7/9 database isolation"
make api-down && make api-up-limited && make ratelimit-scenarios && echo "8/9 rate limiting"
make api-down && make api-up-limited RPS=1000 BURST=1000 \
  && make api-scenarios && make metrics-scenarios && echo "9/9 scenarios"
```

| Check | Expected |
|---|---|
| `make backend-test` | `ok` for every package including `internal/ratelimit` |
| `make ratelimit-scenarios` | 14 passes |
| `make api-scenarios` | 24 passes |
| `make metrics-scenarios` | 17 passes |
| `make db-verify` | 21 passes |
| `make coverage` | no package below its baseline or minimum |

---

## Part 9: troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| Every request returns `200`, nothing throttles | The limiter is off | `grep "rate limiting" .dev/aperture.log`; restart with `make api-up-limited` |
| `rate limiting disabled` despite setting the variable | `make api-up` passes it through, a bare `./aperture` does not | Use `make api-up-limited`, or export the variable before running the binary |
| `api-scenarios` or `metrics-scenarios` fail with 429 | They send requests in tight loops | `make api-up-limited RPS=1000 BURST=1000`, or `make api-up-postgres` |
| `Retry-After` reads `1` when you expected less | RFC 9110 has no sub-second form | Working as intended; rounding down would advertise a moment still too early |
| A tenant is throttled harder than configured | Several devices share the tenant, which is the design | Raise the rate, or reconsider whether the key should be the device |
| Memory grows with the number of tenants | Eviction is not running | `TestIdleKeysAreEvicted` covers it; check `MaxKeys` and `IdleTTL` in `ratelimit.Config` |
| Benchmarks vary wildly between runs | Cloud Shell is a shared VM | `make bench BENCH_TIME=5s BENCH_COUNT=6` and compare medians, not single runs |
| A scenario expects `429` and sees `200` | The bucket refilled while an earlier section was running | Each section now drains before asserting. A scenario that depends on how long the previous one took fails on a slow morning |
| `go: updates to go.mod needed` | `go.mod` and `go.sum` disagree | `make backend-deps`, commit both |
| `no space left on device` | The 5 GB `$HOME` | `go clean -fuzzcache -cache`, `rm -rf ios/Packages/*/.build` |
| Everything worked yesterday, nothing today | VM recycled | Part 2, Part 4 |

### Full teardown

```bash
cd ~/aperture
make api-down
make backend-down
docker compose -f infra/docker-compose.yml down -v
go clean -fuzzcache
rm -rf .dev backend/coverage.out backend/coverage.html
```
