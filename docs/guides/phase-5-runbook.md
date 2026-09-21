# Phase 5 runbook: setup, run, and verify

Self-contained, for a fresh Cloud Shell session.

---

## What Phase 5 contains, and what it does not

| Delivered | Runnable now | Where |
|---|---|---|
| Durable sync operation with in-flight state | **Yes** | `ApertureSync` |
| Per-entity queue ordering, backoff, dead-lettering | **Yes** | `ApertureSync` |
| Note CRDT with algebraic properties tested | **Yes** | `ApertureSync` |
| Per-field conflict policy table | **Yes** | `ApertureSync` |
| Sync engine: pull, apply, push, reconcile | **Yes** | `ApertureSync` |
| **Property-based convergence suite** | **Yes, the centrepiece** | `ApertureSyncTests` |
| Interactive sync scenarios | **Yes** | `ApertureScenarios` |
| SQLite-backed queue | No, Phase 6 with the real store | |
| Wire transport against the Go service | No, Phase 6 | |

**Phase 5 added no backend code.** No Go files, no migrations, no endpoints, no seed data.
The service, schema, and row-level security policies are exactly as Phase 3 left them, and
the sync engine currently talks to an in-memory server double rather than to HTTP. The real
transport lands in Phase 6.

There are therefore no API payloads for this phase. What replaces them is the scenario tool,
which takes the same inputs a wire payload would carry (dirty fields, clocks, seeds) and
reports what the engine decides.

---

## Part 1: verify the existing environment

```bash
cd ~ 2>/dev/null

echo "--- repository ---"
if [ -d ~/aperture/.git ]; then
  cd ~/aperture && git log --oneline -3 && git tag -l && git status --short | head
else
  echo "MISSING: ~/aperture is not a git repository"
fi

echo "--- toolchain ---"
for tool in git docker python3 go gh; do
  printf '%-8s %s\n' "$tool" "$(command -v $tool || echo MISSING)"
done

echo "--- images (gone after a VM recycle) ---"
docker images --format '{{.Repository}}:{{.Tag}}' | grep -E 'swift|postgres' || echo "none"

echo "--- containers ---"
docker ps --format '{{.Names}}\t{{.Status}}' || echo "none running"

echo "--- database volume (does NOT survive a VM recycle) ---"
docker volume ls --format '{{.Name}}' | grep -i aperture || echo "no volume: rebuild with make db-reset"

echo "--- archive ---"
ls -la ~/aperture-phase-5.zip 2>/dev/null && md5sum ~/aperture-phase-5.zip
echo "  compare against the MD5 published with the archive"
```

`$HOME` persists across a VM recycle. Everything Docker holds, images and volumes alike,
does not: it lives on the VM's ephemeral disk, which is the same reason a 2 GB Swift image
does not count against your 5 GB quota. The local database is disposable by design.

---

## Part 2: install or initialize what is missing

```bash
cd ~/aperture
source ~/.bashrc
./scripts/cloudshell_setup.sh      # idempotent
make doctor

docker pull swift:6.3
docker pull postgres:16-alpine
```

Apply the archive after verifying it. **No files were deleted in Phase 5**, so a plain
overlay is complete:

```bash
cd ~
md5sum aperture-phase-5.zip
unzip -oq aperture-phase-5.zip
cd ~/aperture && chmod +x scripts/*.sh scripts/*.py
```

---

## Part 3: environment variables

Unchanged since Phase 3. Nothing in Phase 5 reads configuration: the sync engine takes its
dependencies by injection, which is what lets every scenario below run without a network.

```bash
cd ~/aperture
[ -f .env ] || cp .env.example .env
cat .env
```

| Variable | Value |
|---|---|
| `POSTGRES_USER` | `aperture` |
| `POSTGRES_PASSWORD` | `local-development-only` |
| `POSTGRES_DB` | `aperture` |
| `POSTGRES_PORT` | `5432` |
| `APERTURE_HTTP_ADDR` | `:8080` |
| `APERTURE_LOG_LEVEL` | `debug` |
| `APERTURE_ENVIRONMENT` | `local` |

| Database role | Password | Attributes |
|---|---|---|
| `aperture` | `local-development-only` | SUPERUSER, bypasses row security |
| `aperture_app` | `local-development-only` | NOSUPERUSER, NOBYPASSRLS |

---

## Part 4: start the services

Needed only for the Phase 3 regression in Part 7.5. Phase 5 requires nothing running.

```bash
cd ~/aperture
make backend-up

for i in $(seq 1 30); do
  docker compose -f infra/docker-compose.yml exec -T postgres \
    pg_isready -U aperture -d aperture && break
  sleep 1
done
```

---

## Part 5: verify service health

```bash
curl -s localhost:8080/healthz    # {"status":"ok","version":"local"}
curl -s localhost:8080/readyz     # {"status":"ready"}
curl -s localhost:8080/version
curl -s localhost:8080/nope | python3 -m json.tool     # contract error envelope, not plain text
curl -si -H 'X-Correlation-Id: phase5-001' localhost:8080/healthz | grep -i correlation
```

The Web Preview button opens `/`, where there is no route, so it returns a 404 in the error
envelope. That is correct. Append a path:

```bash
echo "$(cloudshell get-web-preview-url -p 8080)/healthz"
```

---

## Part 6: run the Phase 5 suites

```bash
cd ~/aperture

make check              # boundaries, queue schema, configuration
make core-test-docker   # every Swift suite
make backend-test       # Phase 3 regression, unchanged
```

Expect roughly 195 tests across 29 suites. The Phase 5 additions are **Mergeable note**,
**Conflict policy**, **Sync cycle**, **Queue behavior**, and **Convergence under adversarial
interleaving**.

One suite at a time:

```bash
cd ~/aperture
make suites                       # every suite, with the identifier --filter matches
make core-test-filter FILTER="ConvergenceTests"
make core-test-filter FILTER="MergeableNoteTests"
make core-test-filter FILTER="ConflictResolverTests"
make core-test-filter FILTER="SyncCycleTests"
```

**`--filter` matches the Swift type name, not the `@Suite` display string.** The two
routinely differ: the suite shown as "Mergeable note" is `MergeableNoteTests`, and
"Conflict policy" is `ConflictResolverTests`. A filter that matches nothing exits
successfully with "No matching test cases were run", which reads like a passing run at a
glance, so `make suites` exists to remove the guesswork.

The convergence suite runs twenty-three generated histories. It takes a few seconds rather
than milliseconds, which is the only slow thing in the package and is worth it.

---

## Part 7: test scenarios with inputs and expected results

### 7.1 The conflict policy table

```bash
cd ~/aperture
make scenario ARGS="policy"
```

| Field | Policy |
|---|---|
| `measurement_value` | requiresHumanDecision |
| `defect_class` | requiresHumanDecision |
| `severity` | requiresHumanDecision |
| `note` | mergeText |
| `attached_media` | addWins |
| `status` | serverAuthoritative |
| `assigned_user_id` | serverAuthoritative |
| any `form.*` field | lastWriterWins |

### 7.2 Conflict resolution scenarios

`conflict <local,fields> <remote,fields> [localClockMs] [remoteClockMs]`

**A: different fields, which is the common case and not a conflict.**

```bash
make scenario ARGS="conflict note severity 2000 1000"
```

Expected: `note` merged automatically, `severity` taken from remote, clean. Two actors
editing different fields of one record is concurrency, not disagreement. Treating it as a
conflict would prompt an inspector several times a shift for nothing.

**B: the same measurement on both sides.**

```bash
make scenario ARGS="conflict measurement_value measurement_value 9999 1000"
```

Expected: `REQUIRES A PERSON`, blocked, even though the local clock is nine times newer.
This is the rule the whole table exists for.

**C: notes, which merge rather than compete.**

```bash
make scenario ARGS="conflict note note 1000 2000"
```

Expected: `text merged, both contributions kept`, clean.

**D: media, where add wins.**

```bash
make scenario ARGS="conflict attached_media attached_media 2000 1000"
```

Expected: `unioned`. Losing a photograph is worse than keeping a redundant one.

**E: status, where the server always wins.**

```bash
make scenario ARGS="conflict status status 9999 1000"
```

Expected: `took remote`. A device offline for two days must not overwrite a reviewer's
approval with a stale local transition.

**F: an ordinary template field, decided by the hybrid clock.**

```bash
make scenario ARGS="conflict form.access_notes form.access_notes 5000 1000"
make scenario ARGS="conflict form.access_notes form.access_notes 1000 5000"
```

Expected: local wins in the first, remote in the second. Ordered by hybrid logical clock,
never by wall-clock time.

### 7.3 Note merging

```bash
make scenario ARGS="merge 'Hail bruising on the south slope, 14 hits per square.' 'Extent looks larger than recorded.'"
```

Expected: both sentences present, `commutative: true`, `idempotent: true`. Replicas receive
edits in whatever order the network delivers, and at-least-once delivery means the same edit
arrives twice routinely.

### 7.4 Convergence

`converge <seed> [steps]` generates a history of local edits, remote edits, transport
failures, terminations, and clock jumps, then lets the network settle.

```bash
make scenario ARGS="converge 42 80"
make scenario ARGS="converge 1597 120"
make scenario ARGS="converge 7 200"
```

Expected on every seed: the step trace, then `CONVERGED`, with queued operations equal to
dead-lettered operations. That equality is the assertion: everything either reached the
server or is explicitly surfaced to the user. Nothing silently stuck.

A divergence prints the seed and step count needed to reproduce it exactly, which is the
difference between a flaky test and a bug report.

Seeds used by the automated suite, if you want to reproduce one by hand: 1, 2, 3, 5, 8, 13,
21, 34, 55, 89, 144, 233, 377, 610, 987, 1597.

### 7.5 Phase 3 regression, database

Unchanged by Phase 5, worth confirming after an overlay.

```bash
make db-status     # 2 of 2 migrations; tenants=2 users=4 devices=3
make db-verify     # 8 isolation checks
make db-reset      # if the volume is gone
```

| Seed entity | Identifier |
|---|---|
| Tenant A, Northwind Mutual | `11111111-1111-4111-a111-111111111111` |
| Tenant B, Pacific Grid Utilities | `22222222-2222-4222-a222-222222222222` |
| Dana Reyes, inspector, tenant A | `a1111111-1111-4111-a111-111111111111` |
| Marcus Obi, inspector, tenant B | `b1111111-1111-4111-a111-111111111111` |

---

## Part 8: verify the expected results

```bash
cd ~/aperture
make check                              && echo "1/7 static checks"
make core-test-docker                   && echo "2/7 swift suites"
make backend-test                       && echo "3/7 go suites"
curl -sf localhost:8080/readyz >/dev/null && echo "4/7 service healthy"
make db-verify                          && echo "5/7 tenant isolation"
make scenario ARGS="policy" >/dev/null  && echo "6/7 scenario tool"
make scenario ARGS="converge 42 80" | grep -q CONVERGED && echo "7/7 convergence"
```

| Check | Expected |
|---|---|
| `make check` | boundaries OK, 13 schema assertions, configuration OK |
| `make core-test-docker` | ~195 tests, ~29 suites, 0 failures |
| `make backend-test` | `ok` for `authn`, `tenancy`, `httpx`, `cmd/aperture` |
| `/readyz` | `{"status":"ready"}` |
| `make db-verify` | 8 passes |
| `converge` | `CONVERGED` on every seed tried |

---

## Part 9: troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| Archive MD5 does not match | Stale download; the browser kept an earlier copy | Re-download, re-upload, verify before extracting |
| `make scenario` takes a minute | First run compiles the executable target | Normal. Later runs are seconds |
| `swift test --filter` reports "No matching test cases were run" | The filter matches type names, not `@Suite` display strings | `make suites` to see the identifiers, then `make core-test-filter FILTER=TypeNameTests` |
| A pasted block vanishes after `make core-shell-docker` | The interactive container allocates a TTY and discards buffered input | Use `make core-test-filter` instead of the interactive shell |
| `converge` prints DIVERGED | A genuine convergence bug | Paste the seed and step count. It reproduces exactly |
| Convergence suite slow | Twenty-three generated histories | Expected. It is the only slow suite, and the most valuable |
| `swift: command not found` | VM recycled | `source ~/.bashrc`, or use the container targets |
| `.build` permission denied | An earlier container ran as root | `sudo chown -R $(id -u):$(id -g) ios/Packages/ApertureCore/.build` |
| swift-crypto will not resolve | No egress from the container | `docker run --rm swift:6.3 curl -sI https://github.com` |
| `port is already allocated` | Another Postgres or service | `docker ps`, stop it, or change `POSTGRES_PORT` in `.env` |
| `db-status` shows no tables | Volume gone: recycle, `down -v`, or a prune | `make db-migrate && make db-seed` |
| `db-verify` reports tenant A sees 4 users | Connected as a superuser | The script uses `aperture_app`; confirm with `\du` |
| Everything worked yesterday, nothing today | VM recycled: images, containers and volumes gone, `$HOME` kept | Part 2, Part 4, then `make db-migrate && make db-seed` |
| `ios` workflow fails | Expected until Phase 4b | It compiles the app target, untouched by Phase 5 |

### Full teardown

```bash
cd ~/aperture
make backend-down
docker compose -f infra/docker-compose.yml down -v
docker system prune -af
```
