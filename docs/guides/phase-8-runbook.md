# Phase 8 runbook: setup, run, and verify

Self-contained, for a fresh Cloud Shell session.

---

## What Phase 8 contains

| Delivered | Runnable now | Where |
|---|---|---|
| Prometheus registry, no client dependency | **Yes** | `backend/internal/metrics` |
| Cardinality ceiling with overflow collapse | **Yes** | `backend/internal/metrics` |
| Route templating for bounded labels | **Yes** | `backend/internal/httpx` |
| Request rate, errors, duration middleware | **Yes** | `backend/internal/httpx` |
| Sync outcome and conflict attribution | **Yes** | `backend/internal/httpapi` |
| Authentication failures by reason | **Yes** | `backend/internal/httpapi` |
| Separate metrics listener | **Yes** | `backend/cmd/aperture` |

**No new dependencies.** The exposition format is text, the semantics that matter are
cardinality control and bucket choice rather than encoding, and the previous phase spent
enough on dependency resolution.

**Phase 7 was skipped deliberately.** Its client half is `BGTaskScheduler` and its server
half is APNs, so most of it cannot be verified without a device and Apple credentials,
which is the same blocker as Phase 4b.

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
GOTOOLCHAIN=local go version 2>/dev/null || echo "Go is required (1.23 or newer)"

echo "--- Go dependencies resolved? ---"
ls -la ~/aperture/backend/go.sum 2>/dev/null || echo "go.sum ABSENT: run make backend-deps"

echo "--- ports ---"
curl -sf http://localhost:8080/healthz >/dev/null && echo "  8080 in use" || echo "  8080 free"
curl -sf http://localhost:9090/metrics >/dev/null && echo "  9090 in use" || echo "  9090 free"

echo "--- containers and volumes (neither survives a VM recycle) ---"
docker ps --format '{{.Names}}\t{{.Status}}' || echo "none running"
docker volume ls --format '{{.Name}}' | grep -i aperture || echo "no database volume"

echo "--- disk, which this project runs close to ---"
df -h ~ | tail -1

echo "--- archive ---"
ls -la ~/aperture-phase-8.zip 2>/dev/null && md5sum ~/aperture-phase-8.zip
echo "  compare against the MD5 published with the archive"
```

---

## Part 2: install or initialize what is missing

```bash
cd ~/aperture
source ~/.bashrc
./scripts/cloudshell_setup.sh      # idempotent
docker pull postgres:16-alpine
```

Cloud Shell ships Go 1.22, below this repository's floor of 1.23. If `go version` reports
anything older, install one under `$HOME`, where it survives a VM recycle:

```bash
cd /tmp
curl -fLO https://go.dev/dl/go1.24.7.linux-amd64.tar.gz
rm -rf ~/.local/go && tar -C ~/.local -xzf go1.24.7.linux-amd64.tar.gz
grep -q 'local/go/bin' ~/.bashrc || echo 'export PATH="$HOME/.local/go/bin:$PATH"' >> ~/.bashrc
export PATH="$HOME/.local/go/bin:$PATH"
GOTOOLCHAIN=local go version
```

Apply the archive. **No files were deleted in Phase 8:**

```bash
cd ~
md5sum aperture-phase-8.zip
unzip -oq aperture-phase-8.zip
cd ~/aperture && chmod +x scripts/*.sh scripts/*.py

# Only needed if an archive changed backend/go.mod, which archives from Phase 8 onward
# no longer do: the pin is committed, so overwriting it would only revert your local tidy.
make backend-deps
```

If your network cannot reach the Go module proxy, which Cloud Shell often cannot:

```bash
go env -w GOPROXY=direct GOSUMDB=off GOTOOLCHAIN=local
make backend-deps
```

---

## Part 3: configure environment variables

One new variable in this phase.

| Variable | Default | Purpose |
|---|---|---|
| `APERTURE_METRICS_ADDR` | `127.0.0.1:9090` | **Separate listener** for the scrape endpoint. Empty disables it |
| `APERTURE_DATABASE_URL` | *(empty)* | Empty selects the in-memory store |
| `APERTURE_JWKS_PATH` | *(empty)* | Empty disables the sync endpoints |
| `APERTURE_TOKEN_ISSUER` | `https://dev.aperture.local` | Required `iss` claim |
| `APERTURE_TOKEN_AUDIENCE` | `aperture-api` | Required `aud` claim |
| `APERTURE_MINIMUM_CLIENT_VERSION` | `0.1.0` | Clients below this receive 426 |
| `APERTURE_HTTP_ADDR` | `:8080` | API listener |
| `APERTURE_LOG_LEVEL` | `info` | `debug` for the scenarios below |
| `APERTURE_ENVIRONMENT` | `local` | Appears in every structured log line |

**Why a separate listener rather than a route.** A metrics endpoint discloses request
volumes, error rates, and tenant activity patterns. That is competitive intelligence about
a customer's operations even though it contains no inspection data, and it should not be
reachable from wherever the API is reachable. Locally it binds to loopback; in a cluster it
binds to the pod address and only the scraper can reach it.

---

## Part 4: start the services

```bash
cd ~/aperture
make backend-up                # Postgres only
make db-migrate && make db-seed

make api-down && make api-up-postgres
```

The metrics listener starts with the service. Confirm from the log:

```bash
grep "metrics listener started" .dev/aperture.log
```

To run without it:

```bash
make api-down
APERTURE_METRICS_ADDR= make api-up-postgres
```

---

## Part 5: verify service and metrics health

```bash
curl -s localhost:8080/healthz
curl -s localhost:8080/readyz
curl -s localhost:8080/version

curl -sI localhost:9090/metrics | head -3
make metrics | head -20
```

Expected from the scrape: `# HELP` and `# TYPE` lines, then series. Before any traffic only
a few metrics exist, because a counter that has never been incremented is not exported at
all. That is correct Prometheus behaviour, not a missing metric.

Confirm the endpoint is **not** on the public listener:

```bash
curl -s -o /dev/null -w '%{http_code}\n' localhost:8080/metrics    # 404
```

---

## Part 6: run the Phase 8 suites

```bash
cd ~/aperture

make check                     # includes the Go alignment and lint pattern checks
make backend-fmt-check
make backend-vet               # go test runs only a subset of vet
make backend-test              # 17 new tests across metrics and httpx
make metrics-scenarios         # 17 assertions against the running service
```

The unit tests cover the registry in isolation: accumulation, determinism, label sorting,
cardinality bounds, overflow arithmetic, cumulative buckets, the mandatory `+Inf` bucket,
escaping, and gauge semantics. `metrics-scenarios` covers the same properties end to end
against real traffic.

---

## Part 7: test scenarios with inputs and expected results

Every scenario runs in `make metrics-scenarios`. They are written out so you can run them
individually and read the output.

### 7.1 Dummy values

| Name | Value |
|---|---|
| Tenant A, Northwind Mutual | `11111111-1111-4111-a111-111111111111` |
| Dana Reyes, inspector | subject `00uDANA0001` |
| API | `http://localhost:8080` |
| Metrics | `http://localhost:9090/metrics` |

```bash
cd ~/aperture
TOKEN=$(make -s api-token TENANT=11111111-1111-4111-a111-111111111111 SUBJECT=00uDANA0001)

value() {
  curl -s localhost:9090/metrics | python3 -c "
import sys
needle = sys.argv[1]
for line in sys.stdin:
    name, _, v = line.strip().rpartition(' ')
    if name == needle: print(v); raise SystemExit
print('0')" "$1"
}
```

### 7.2 Determinism

```bash
diff <(curl -s localhost:9090/metrics) <(curl -s localhost:9090/metrics) && echo "identical"
```

Expected: no differences. Go randomises map iteration, so an unsorted registry would
reorder between scrapes, making every diff unreadable and every test flaky.

### 7.3 Request counters, including rejected requests

```bash
value 'aperture_http_requests_total{method="GET",route="/v1/me",status="200"}'
for i in 1 2 3; do curl -s -o /dev/null -H "Authorization: Bearer $TOKEN" localhost:8080/v1/me; done
value 'aperture_http_requests_total{method="GET",route="/v1/me",status="200"}'

curl -s -o /dev/null localhost:8080/v1/me         # no token
value 'aperture_http_requests_total{method="GET",route="/v1/me",status="401"}'
```

Expected: the success counter advances by three, the 401 counter by one. The middleware sits
outside authentication deliberately: a metrics layer that only sees traffic which got past
the gate cannot show you an outage at the gate.

### 7.4 Cardinality control, the scenario that matters most

```bash
value 'aperture_http_requests_total{method="GET",route="other",status="404"}'

for i in $(seq 1 50); do
  curl -s -o /dev/null "localhost:8080/v1/attacker/controlled/path-$i"
done

value 'aperture_http_requests_total{method="GET",route="other",status="404"}'
curl -s localhost:9090/metrics | grep -c '^aperture_http_requests_total{'
```

Expected: the `other` counter advances by fifty, and the total number of series stays in
single digits.

If the route label came from the request path, those fifty requests would have created
fifty time series, and a caller can invent as many paths as they like. Prometheus stores
one series per label combination, so the failure is a monitoring outage arriving during
whatever traffic spike caused it. Identifiers collapse to `:id` and unrecognised paths to
`other`, against an explicit allow-list.

### 7.5 The latency histogram

```bash
curl -s localhost:9090/metrics | grep 'aperture_http_request_duration_seconds' | head -20
```

Three things to check:

```bash
curl -s localhost:9090/metrics | grep -q 'duration_seconds_bucket{.*le="+Inf"}' && echo "+Inf present"
curl -s localhost:9090/metrics | grep -q 'duration_seconds_bucket{.*le="0.3"' && echo "objective boundary present"
curl -s localhost:9090/metrics | grep 'duration_seconds' | grep -q 'status=' && echo "PROBLEM: labelled by status" || echo "not labelled by status"
```

`+Inf` is mandatory in the format; without it the histogram is silently unusable for
quantiles and nothing complains. The boundary at 0.300 exists because that is the sync
objective, and a histogram whose boundaries do not straddle the target cannot report
compliance. Duration excludes status because mixing them means fast failures drag the
quantile down during an incident, and the graph improves as things get worse.

### 7.6 Authentication failures, by reason

```bash
value 'aperture_auth_failures_total{reason="expired"}'

EXPIRED=$(.dev/devtoken mint -key .dev/dev-key.pem \
  -tenant 11111111-1111-4111-a111-111111111111 -subject 00uDANA0001 -ttl -5m)
curl -s -o /dev/null -H "Authorization: Bearer $EXPIRED" localhost:8080/v1/me
curl -s -o /dev/null -H "Authorization: Bearer garbage" localhost:8080/v1/me
curl -s -o /dev/null localhost:8080/v1/me

curl -s localhost:9090/metrics | grep aperture_auth_failures_total
```

Expected: separate counters for `expired`, `malformed`, and `missing`.

The caller is told none of this, deliberately: distinguishing signature failure from expiry
in a response is a probing oracle. This counter is the only place the distinction survives,
and it matters operationally, since a spike in `expired` is a clock problem while a spike in
`bad_signature` is a key rotation or an attack.

The label values come from a closed set, never from the error text, because error strings
can carry a token fragment or an issuer URL and a metric label is stored forever.

### 7.7 Sync outcomes and conflict attribution

```bash
ENTITY="f-metrics-$(date +%s)"
push() {
  curl -s -o /dev/null -X POST localhost:8080/v1/sync/deltas \
    -H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/json' \
    -d "{\"operations\":[{\"operation_id\":\"$1\",\"entity_type\":\"finding\",
         \"entity_id\":\"$ENTITY\",\"kind\":\"$2\",\"dirty_fields\":[\"$3\"],
         \"base_version\":$4,\"hlc\":\"h\",\"payload\":{\"$3\":\"v\"}}]}"
}

push mx-1 create measurement_value 0     # applied
push mx-1 create measurement_value 0     # replayed, same key
push mx-2 update measurement_value 0     # conflict, stale base version

curl -s localhost:9090/metrics | grep -E 'aperture_sync_(operations|conflicts)_total'
```

Expected: `applied` up one, `replayed` up one, and
`aperture_sync_conflicts_total{field="measurement_value"}` up one.

Every push returns HTTP 200 whatever happened inside it, because each operation carries its
own status. Without these counters, a fleet whose operations all conflict looks identical on
a dashboard to one where everything applies cleanly. `replayed` is separate from `applied`
because a rising replay rate is the signature of a client retry storm.

### 7.8 Exposure

```bash
curl -s -o /dev/null -w '%{http_code}\n' localhost:8080/metrics    # 404
curl -s -o /dev/null -w '%{http_code}\n' localhost:9090/metrics    # 200
ss -ltnp 2>/dev/null | grep 9090 || netstat -ltnp 2>/dev/null | grep 9090
```

Expected: the metrics listener is bound to `127.0.0.1`, not `0.0.0.0`.

### 7.9 Earlier phases, unchanged

```bash
make db-verify         # 21 isolation checks
make api-scenarios     # 23 API scenarios
```

Note the ordering hazard: `make backend-test-integration` drops and rebuilds the schema, so
run `make db-seed` before `make db-verify` after any integration run.

---

## Part 8: verify the expected results

```bash
cd ~/aperture
make check                     && echo "1/7 static checks"
make backend-fmt-check         && echo "2/7 formatting"
make backend-test-integration  && echo "3/7 go suites with the store tests"
make db-seed && make db-verify && echo "4/7 database isolation"
curl -sf localhost:8080/readyz >/dev/null && echo "5/7 service healthy"
make api-scenarios             && echo "6/7 api scenarios"
make metrics-scenarios         && echo "7/7 metrics scenarios"
```

| Check | Expected |
|---|---|
| `make check` | boundaries, driver isolation, module floor, alignment, lint patterns |
| `make backend-test-integration` | `ok` for every package including `internal/metrics` |
| `make db-verify` | 21 passes |
| `make api-scenarios` | 23 passes |
| `make metrics-scenarios` | 17 passes |

---

## Part 9: troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| `metrics endpoint is not answering` | Listener disabled or on another port | `grep "metrics listener" .dev/aperture.log`; default is `127.0.0.1:9090` |
| A counter reads `0` for a series you expect | A counter with no observations is not exported at all | Correct Prometheus behaviour. Drive traffic first |
| A scenario fails with `replayed` where `applied` is expected | An operation id reused across runs against a persistent store | Fixed: both scripts suffix every id per run. Otherwise `make db-reset` |
| A scenario asserting a row count fails after other tests ran | Counting assumes nothing else shares the table | The isolation checks assert on identity instead. Report any that still count |
| Series count grows with traffic | A label is taking a value from user input | `RouteTemplate` collapses unknown paths; check any new `Labels{}` for unbounded values |
| `overflow` appears in the output | A metric hit the 200-series ceiling | Find the unbounded label. Totals stay correct; the attribution does not |
| Scrape output reorders between calls | Should not happen | The registry sorts. Report it, since a test depends on it |
| `port is already allocated` on 9090 | Something else is bound | `APERTURE_METRICS_ADDR=127.0.0.1:9091 make api-up`, and set `METRICS_URL` for the scenarios |
| Metrics reachable on 8080 | Should not happen | The listeners are separate servers. Check `APERTURE_METRICS_ADDR` |
| `updates to go.mod needed` | `go.mod` and `go.sum` disagree, usually after an overlay replaced one of them | `make backend-deps`, then commit both together. `make check` now catches this when Go is on PATH |
| CI fails on `go vet` with the same message | The mismatch was committed | Same fix. `go.sum` is only meaningful against the `go.mod` that produced it |
| `method WriteTo should have signature ...` | A method named after a standard interface with a different shape; `go test` does not run this vet check | Rename the method. `make backend-vet` and `make check` both catch it now |
| `no space left on device` | The 5 GB `$HOME` is full | `rm -rf ios/Packages/*/.build`, `go clean -cache -modcache`, `rm -rf ~/go/pkg/mod/golang.org/toolchain*` |
| `make: *** [api-down] Terminated` | Fixed in Phase 6b | Update to the current archive |
| Everything worked yesterday, nothing today | VM recycled: images, containers, volumes and processes gone | Part 2, Part 4 |

### Full teardown

```bash
cd ~/aperture
make api-down
make backend-down
docker compose -f infra/docker-compose.yml down -v
rm -rf .dev
```
