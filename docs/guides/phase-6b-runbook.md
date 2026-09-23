# Phase 6b runbook: setup, run, and verify

Self-contained, for a fresh Cloud Shell session.

---

## What Phase 6b contains

The persistence layer. Everything the API did in 6a now survives a restart.

| Delivered | Runnable now | Where |
|---|---|---|
| `sync_entities`, `sync_changes`, `sync_idempotency` with row-level security | **Yes** | `backend/migrations/0003_sync.sql` |
| Application grants, append-only change log | **Yes** | `infra/db/0004_sync_grants.sql` |
| PostgreSQL implementation of the `Store` interface | **Yes** | `backend/internal/store` |
| Store chosen by configuration at startup | **Yes** | `backend/cmd/aperture` |
| Integration tests against real PostgreSQL | **Yes** | `backend/internal/store` |
| Database service in CI, so those tests run | **Yes** | `.github/workflows/pr.yml` |
| Driver confined to one package, enforced | **Yes** | `scripts/check_module_boundaries.py` |

**This phase adds the project's first third-party Go dependency**, a PostgreSQL driver.
`go.sum` holds cryptographic module checksums, so it is generated rather than written, and
nothing builds until you run one command. Part 2 covers it.

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
for tool in git go docker python3 curl psql; do
  printf '%-8s %s\n' "$tool" "$(command -v $tool || echo MISSING)"
done
go version 2>/dev/null || echo "Go is required"

echo "--- Go dependencies resolved? ---"
ls -la ~/aperture/backend/go.sum 2>/dev/null || echo "go.sum ABSENT: run make backend-deps"

echo "--- containers and volumes (neither survives a VM recycle) ---"
docker ps --format '{{.Names}}\t{{.Status}}' || echo "none running"
docker volume ls --format '{{.Name}}' | grep -i aperture || echo "no database volume"

echo "--- is anything on port 8080 ---"
curl -sf http://localhost:8080/healthz >/dev/null && echo "  something is serving" || echo "  port is free"

echo "--- local API artifacts ---"
ls -la ~/aperture/.dev 2>/dev/null || echo "no .dev directory yet"

echo "--- archive ---"
ls -la ~/aperture-phase-6b.zip 2>/dev/null && md5sum ~/aperture-phase-6b.zip
echo "  compare against the MD5 published with the archive"
```

`$HOME` persists across a VM recycle, including `.dev/`. Docker images, containers, and
volumes do not: they live on the VM's ephemeral disk, which is the same reason a 2 GB Swift
image does not count against your 5 GB quota.

---

## Part 2: install or initialize what is missing

```bash
cd ~/aperture
source ~/.bashrc
./scripts/cloudshell_setup.sh      # idempotent
docker pull postgres:16-alpine
docker pull swift:6.3              # only for the Swift suites
```

Apply the archive after verifying it. **No files were deleted in Phase 6b:**

```bash
cd ~
md5sum aperture-phase-6b.zip
unzip -oq aperture-phase-6b.zip
cd ~/aperture && chmod +x scripts/*.sh scripts/*.py

# Always, after applying an archive that touches the backend.
#
# The archive ships a go.mod carrying the pinned version and nothing else; the indirect
# requirements are regenerated locally. Overlaying it therefore reverts a previous tidy,
# and the next Go command fails with "updates to go.mod needed". This costs seconds and
# needs no network once the module cache is warm.
make backend-deps
```

### The one required step

```bash
cd ~/aperture
make backend-deps
```

**If your environment cannot reach `proxy.golang.org`**, which happens in Cloud Shell, fetch
from the source instead:

```bash
cd ~/aperture/backend
go version                    # the real one; go.mod can make this misleading

GOTOOLCHAIN=local GOPROXY=direct GOSUMDB=off go mod tidy
go build ./... && go vet ./...
```

Three settings, each doing something specific:

| Setting | Why |
|---|---|
| `GOPROXY=direct` | Fetch from GitHub rather than the module proxy |
| `GOSUMDB=off` | The checksum database is on the same unreachable host |
| `GOTOOLCHAIN=local` | **Do not let Go upgrade its own toolchain.** Without this, a dependency needing a newer language version silently rewrites `go.mod` and downloads a compiler, and the download is verified against the checksum database that is already off |

`GOSUMDB=off` is a real reduction, worth naming. You lose the transparency-log check that
the module you downloaded is the one everyone else downloads. You keep `go.sum`, computed
from the bytes actually fetched, so every later build verifies against it, and CI reaches
the checksum database normally and will verify your committed `go.sum` against it.

Persist the settings for this machine:

```bash
go env -w GOPROXY=direct GOSUMDB=off GOTOOLCHAIN=local
```

### Version pinning, and why it is not optional here

The driver is pinned to `pgx v5.7.5` in `go.mod`, and `make backend-deps` re-applies the
pin before resolving. Unpinned, `go mod tidy` selects the newest release; `v5.11` requires
Go 1.25, so Go rewrites the module's `go` directive and downloads a newer compiler to
compensate. That is a large change to make on the strength of a `go get`, and where the
checksum database is unreachable it fails after having already rewritten `go.mod`.

`make check` fails if anything raises the declared version above 1.23, naming the likely
cause. The floor is set by the dependency rather than by the service: nothing here needs
newer than `log/slog`, which arrived in 1.21.

**Cloud Shell ships Go 1.22.12**, which is below that floor. Install a current Go under
`$HOME`, where it survives a VM recycle:

```bash
cd /tmp
curl -fLO https://go.dev/dl/go1.24.7.linux-amd64.tar.gz
rm -rf ~/.local/go && tar -C ~/.local -xzf go1.24.7.linux-amd64.tar.gz
grep -q 'local/go/bin' ~/.bashrc || echo 'export PATH="$HOME/.local/go/bin:$PATH"' >> ~/.bashrc
export PATH="$HOME/.local/go/bin:$PATH"
go version
```

Note that `go version` honours the `toolchain` line in `go.mod`, so it can report a version
that is not the binary on your PATH. `GOTOOLCHAIN=local go version` reports the real one.

That runs `go mod tidy`, which resolves the driver version and writes `go.sum`. A `go.sum`
entry is a module checksum, so it cannot be written by hand: inventing one defeats the
mechanism it exists for. `make backend-test` and the CI job both fail with this instruction
rather than a compiler error listing every file that imports the driver.

Commit the result, since it pins exactly what was tested:

```bash
git add backend/go.mod backend/go.sum
git commit -m "chore(backend): resolve the PostgreSQL driver dependency"
```

---

## Part 3: configure environment variables

One new variable, and it selects the whole persistence strategy.

| Variable | Default | Purpose |
|---|---|---|
| `APERTURE_DATABASE_URL` | *(empty)* | **Empty selects the in-memory store.** Set it to use PostgreSQL |
| `APERTURE_JWKS_PATH` | *(empty)* | Key set for token verification. Empty disables the sync endpoints |
| `APERTURE_TOKEN_ISSUER` | `https://dev.aperture.local` | Required `iss` claim |
| `APERTURE_TOKEN_AUDIENCE` | `aperture-api` | Required `aud` claim |
| `APERTURE_MINIMUM_CLIENT_VERSION` | `0.1.0` | Clients below this receive 426 |
| `APERTURE_HTTP_ADDR` | `:8080` | Listen address |
| `APERTURE_LOG_LEVEL` | `info` | `debug` for the scenarios below |
| `APERTURE_ENVIRONMENT` | `local` | Appears in every log line |
| `APERTURE_TEST_DATABASE_URL` | *(empty)* | Set for the store integration tests; empty skips them |

Connection strings for local development:

| Role | URL |
|---|---|
| Application, `NOSUPERUSER` `NOBYPASSRLS` | `postgres://aperture_app:local-development-only@localhost:5432/aperture?sslmode=disable` |
| Bootstrap, SUPERUSER, migrations only | `postgres://aperture:local-development-only@localhost:5432/aperture?sslmode=disable` |

The service connects as `aperture_app`. That is not a detail: superusers bypass row-level
security regardless of `FORCE ROW LEVEL SECURITY`, so a service connected as the bootstrap
role would have policies present and inert.

`make api-up-postgres` supplies the application URL for you.

---

## Part 4: start the services

```bash
cd ~/aperture
make backend-up

make db-migrate     # applies 0001, 0002, 0003, 0004
make db-seed
make db-status      # expect "4 of 4 migration file(s) recorded"
```

`make backend-up` starts **Postgres only** and waits for it to accept connections. The
service is not in that container: it runs natively via `make api-up`, which is faster to
iterate on and avoids fetching Go modules inside a Docker build, where the host's `GOPROXY`
settings do not apply. On a network that blocks the module proxy, building that image fails
and takes the database down with it.

If you do want the containerised service:

```bash
GOPROXY=direct GOSUMDB=off make backend-up-service
```

Then the API, against PostgreSQL:

```bash
make api-down          # also catches a service started by hand
make api-up-postgres
grep "PostgreSQL store" .dev/aperture.log
```

You want `using the PostgreSQL store`. If it says `using the in-memory store`, the URL did
not reach the process and everything below will pass while proving nothing about
persistence.

To go back to the in-memory store, which is still the right default for most work:

```bash
make api-down && make api-up
```

---

## Part 5: verify service health

```bash
curl -s localhost:8080/healthz    # {"status":"ok","version":"dev"}
curl -s localhost:8080/readyz     # {"status":"ready"}
curl -s localhost:8080/version
curl -s localhost:8080/nope | python3 -m json.tool      # contract error envelope
curl -si -H 'X-Correlation-Id: phase6b-001' localhost:8080/healthz | grep -i correlation
```

Confirm the store choice and that the endpoints mounted:

```bash
grep -E "sync endpoints|PostgreSQL store|in-memory store" .dev/aperture.log
```

Confirm the service is actually talking to the database:

```bash
docker compose -f infra/docker-compose.yml exec -T postgres \
  psql -U aperture -d aperture -c \
  "SELECT usename, application_name, state FROM pg_stat_activity WHERE datname = 'aperture'"
```

You want rows for `aperture_app`. If every row says `aperture`, the service is connected as
the bootstrap superuser and row-level security is not being enforced on its queries.

---

## Part 6: run the Phase 6b suites

```bash
cd ~/aperture

make check                     # boundaries, driver isolation, schema, configuration, Swift lengths
make backend-fmt-check
make backend-test              # unit suites; store tests skip without a database
make backend-test-integration  # the same suites with the store tests running
make db-verify                 # 21 isolation checks, now including the sync tables
make api-scenarios             # 23 API scenarios against the running service
```

`make check` now also asserts that only `internal/store` imports a database driver. Tenant
scoping is applied when a session opens, so a second package able to open one would make
that scoping a convention rather than a property.

The difference between `backend-test` and `backend-test-integration` is worth seeing once:

```bash
make backend-test 2>&1 | grep -c "no test files\|ok  "
cd backend && go test ./internal/store/ -v -run TestTenant 2>&1 | head -5; cd ..
```

Without `APERTURE_TEST_DATABASE_URL` those tests report `SKIP`. A suite that silently skips
its most important assertions is indistinguishable from one that passes them, which is why
CI now runs a PostgreSQL service container.

---

## Part 7: test scenarios with inputs and expected results

### 7.1 Dummy values

| Name | Value |
|---|---|
| Tenant A, Northwind Mutual | `11111111-1111-4111-a111-111111111111` |
| Tenant B, Pacific Grid Utilities | `22222222-2222-4222-a222-222222222222` |
| Dana Reyes, inspector, tenant A | subject `00uDANA0001` |
| Marcus Obi, inspector, tenant B | subject `00uMARCUS01` |
| Seeded entity, tenant A | `seed-finding-a` |
| Seeded entity, tenant B | `seed-finding-b` |
| Issuer / audience | `https://dev.aperture.local` / `aperture-api` |

```bash
cd ~/aperture
TOKEN_A=$(make -s api-token TENANT=11111111-1111-4111-a111-111111111111 SUBJECT=00uDANA0001)
TOKEN_B=$(make -s api-token TENANT=22222222-2222-4222-a222-222222222222 SUBJECT=00uMARCUS01)
```

### 7.2 The scenario this phase exists for: persistence across a restart

In Phase 6a this was impossible. Run it against PostgreSQL.

```bash
# Write something
curl -s -X POST localhost:8080/v1/sync/deltas \
  -H "Authorization: Bearer $TOKEN_A" -H 'Content-Type: application/json' \
  -d '{"operations":[{"operation_id":"persist-1","entity_type":"finding",
       "entity_id":"f-persist","kind":"create","dirty_fields":["note"],
       "base_version":0,"hlc":"2026-09-10T00:26:40.123Z-0000-devA",
       "payload":{"note":"written before the restart"}}]}' | python3 -m json.tool

# Restart the process entirely
make api-down && make api-up-postgres

# The change is still there
TOKEN_A=$(make -s api-token TENANT=11111111-1111-4111-a111-111111111111 SUBJECT=00uDANA0001)
curl -s -H "Authorization: Bearer $TOKEN_A" \
  localhost:8080/v1/sync/changes | python3 -m json.tool
```

Expected: the `f-persist` change is present. Repeat the same sequence after `make api-down
&& make api-up` (no `DATABASE_URL`) and it will be gone, which is the in-memory store
behaving correctly.

### 7.3 Idempotency survives a restart

```bash
# Send the identical operation again after the restart
curl -s -X POST localhost:8080/v1/sync/deltas \
  -H "Authorization: Bearer $TOKEN_A" -H 'Content-Type: application/json' \
  -d '{"operations":[{"operation_id":"persist-1","entity_type":"finding",
       "entity_id":"f-persist","kind":"create","dirty_fields":["note"],
       "base_version":0,"hlc":"2026-09-10T00:26:40.123Z-0000-devA",
       "payload":{"note":"written before the restart"}}]}' | python3 -m json.tool
```

Expected: `"status":"replayed"`, `"server_version":1`. Exactly-once effect now holds across
a process restart, not merely within one. A device that retried after a crash on both sides
still produces one server-side effect.

### 7.4 Tenant isolation over HTTP, backed by database policies

```bash
curl -s -H "Authorization: Bearer $TOKEN_B" \
  localhost:8080/v1/sync/changes | python3 -m json.tool
```

Expected: only tenant B's own changes, including `seed-finding-b` and not `seed-finding-a`.
The filtering happens in PostgreSQL, so even a query that forgot its `WHERE` clause returns
nothing rather than another carrier's inspections.

Prove that directly:

```bash
./scripts/db.sh app-psql
```

```sql
-- No scope: the policy has nothing to match.
SELECT count(*) FROM sync_entities;                    -- 0

BEGIN;
SELECT set_config('app.tenant_id', '11111111-1111-4111-a111-111111111111', true);
SELECT entity_id FROM sync_entities;                   -- only tenant A's
SELECT count(*) FROM sync_entities WHERE entity_id = 'seed-finding-b';   -- 0
COMMIT;

-- Outside the transaction the scope is gone again. is_local = true is what stops a pooled
-- connection carrying one tenant's scope into the next request.
SELECT count(*) FROM sync_entities;                    -- 0

-- Append-only, as a grant rather than a convention.
UPDATE sync_changes SET hlc = 'rewritten';             -- ERROR: permission denied
DELETE FROM sync_changes;                              -- ERROR: permission denied

-- Writing into another tenant is refused by WITH CHECK.
BEGIN;
SELECT set_config('app.tenant_id', '11111111-1111-4111-a111-111111111111', true);
INSERT INTO sync_entities (tenant_id, entity_type, entity_id, version, hlc)
VALUES ('22222222-2222-4222-a222-222222222222', 'finding', 'forged', 1, 'h');
-- ERROR: new row violates row-level security policy
ROLLBACK;

\q
```

### 7.5 The store integration suite

```bash
cd ~/aperture/backend
export APERTURE_TEST_DATABASE_URL="postgres://aperture:local-development-only@localhost:5432/aperture?sslmode=disable"
go test ./internal/store/ -v
unset APERTURE_TEST_DATABASE_URL
cd ..
```

| Test | What it asserts |
|---|---|
| `TestEntityRoundTrips` | jsonb fields and field versions survive a write and a read |
| `TestTenantCannotReadAnotherTenantsEntity` | Same entity id, different tenant, reported as **absent** rather than forbidden |
| `TestChangeLogIsScopedToTheTenant` | Asserted on identifiers as well as count |
| `TestUnscopedContextIsRefused` | An unscoped read fails loudly rather than returning empty |
| `TestIdempotencyIsScopedToTheTenant` | One tenant never receives another's stored response |
| `TestStoredResultIsNotReEvaluatedOnRetry` | The first answer is the one the client keeps receiving |
| `TestCursorPagesInOrder` | Paging advances and does not repeat |

**The harness drops and rebuilds the schema on every run**, applies every migration in
numeric order, and then asserts that `aperture_app` is `NOSUPERUSER` and `NOBYPASSRLS`
before connecting as it. Without that assertion a superuser connection would pass every
isolation test against policies that were never consulted.

### 7.6 The full API scenario suite

```bash
cd ~/aperture
make api-scenarios
```

Expected: 23 passes. These now run against PostgreSQL rather than memory, so the conflict,
replay, and isolation scenarios are exercising database policies.

The scenarios are re-runnable against a persistent store. Every operation id and entity id
carries a per-run suffix, because idempotency is keyed by tenant and operation id: a fixed
id returns the stored result from a previous run, and the first push reports `replayed`
rather than `applied` for a reason that has nothing to do with the service.

### 7.7 Row-level security regression

```bash
make db-verify
```

Expected: 21 passes, including the seven new sync-table checks. The one to read is
`an unscoped session sees no sync entities`. A policy that fails open is worse than no
policy, because it looks like protection.

---

## Part 8: verify the expected results

```bash
cd ~/aperture
make check                     && echo "1/7 static checks and driver isolation"
make backend-fmt-check         && echo "2/7 formatting"
make backend-test-integration  && echo "3/7 go suites with the store tests"
make db-verify                 && echo "4/7 database isolation"
curl -sf localhost:8080/readyz >/dev/null && echo "5/7 service healthy"
make api-scenarios             && echo "6/7 api scenarios"
make core-test-docker          && echo "7/7 swift suites"
```

| Check | Expected |
|---|---|
| `make check` | boundaries OK, driver confined to the store package, 13 schema assertions |
| `make backend-test-integration` | `ok` for every package including `internal/store` |
| `make db-verify` | 21 passes, "Tenant isolation verified" |
| `make api-scenarios` | 23 passes |
| `make core-test-docker` | ~194 tests, 30 suites |

---

## Part 9: troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| `no required module provides package github.com/jackc/pgx` | Dependencies not resolved | `make backend-deps`, then commit `go.mod` and `go.sum` |
| `backend/go.sum is missing` | Same | `make backend-deps` |
| `updates to go.mod needed; to update it: go mod tidy` | An archive overlay replaced `go.mod`, reverting the indirect requirements | `make backend-deps`. `make backend-deps-check` now catches this before any Go command runs |
| `dial tcp ...: connection refused` fetching modules | `proxy.golang.org` unreachable | `GOPROXY=direct GOSUMDB=off GOTOOLCHAIN=local go mod tidy` |
| `toolchain upgrade needed` or `switching to go1.x` | A dependency requires a newer language version than `go.mod` declares | Pin the dependency lower. `GOTOOLCHAIN=local` turns the silent upgrade into an error |
| `verifying module: checksum database disabled` | Go is downloading a toolchain while `GOSUMDB=off` | `GOTOOLCHAIN=local`, and keep `go.mod` at a version your local Go satisfies |
| `go.mod requires go >= 1.x (running go 1.y)` | `go.mod` was rewritten by a failed tidy | `go mod edit -go=1.23`, remove any `toolchain` line, then re-resolve |
| `finding module for package github.com/jackc/pgx/v5` | The `require` line is missing, so tidy is selecting the newest release | `make backend-deps`, which re-applies the pin first |
| `requires go >= 1.25.0` after pinning | The pin did not apply: `go get` cannot run while the module graph is unloadable | `go mod edit -require=...`, which is textual and needs no network |
| Local Go is older than the module floor | Cloud Shell ships 1.22.12 | Install a current Go under `$HOME`, see Part 2 |
| `go version` disagrees with what is actually running | `go version` honours the toolchain line in `go.mod` | `GOTOOLCHAIN=local go version` reports the binary on your PATH |
| Log says `using the in-memory store` | `APERTURE_DATABASE_URL` did not reach the process | `make api-down && make api-up-postgres` |
| Data disappears after a restart | The in-memory store is running | Check the log line above |
| `store: database unreachable` at startup | Postgres not running, or wrong port | `make backend-up`, check `POSTGRES_PORT` in `.env` |
| `go mod download` fails during a Docker build | The container cannot reach the module proxy, and host `go env` settings do not apply inside it | `make backend-up` no longer builds it. For the container: `GOPROXY=direct GOSUMDB=off make backend-up-service` |
| Store tests fail with `connection refused` on 5432 | Postgres is not running | `make backend-up`. Failing loudly is correct here: the alternative is skipping the assertions that matter most |
| `no space left on device` | The 5 GB `$HOME` is full | `rm -rf ios/Packages/*/.build`, `go clean -cache -modcache`, `rm -rf ~/go/pkg/mod/golang.org/toolchain*` |
| `relation "sync_entities" does not exist` | Migration 0003 not applied | `make db-migrate`, then `make db-status` |
| `permission denied for table sync_entities` | Grants from 0004 not applied | `make db-migrate` |
| `pg_stat_activity` shows only `aperture` | The service is connected as the superuser, so policies are inert | Use `make api-up-postgres`, which supplies the application URL |
| Store tests report `SKIP` | `APERTURE_TEST_DATABASE_URL` unset | `make backend-test-integration` |
| Store tests fail on `DROP SCHEMA` | Connected as a non-owner | Use the bootstrap URL, not the application one |
| `db-verify` says tenant A sees 4 users | Connected as a superuser | The script uses `aperture_app`; confirm with `\du` |
| `api-scenarios` reports unexpected `replayed` | An operation id reused across runs; idempotency is keyed by tenant and operation id, not by entity | Fixed: every id now carries a per-run suffix. Otherwise `make db-reset` |
| `make api-up` says the port is in use | An earlier service is still running | `make api-down`, which also catches hand-started processes |
| `make: *** [api-down] Terminated` | `pkill -f` matched the shell running the recipe and killed its own parent | Fixed: `api-down` matches by process name with `pkill -x aperture` |
| `make check` reports hundreds of Swift findings | A checker walking `.build` | Fixed; otherwise `rm -rf ios/Packages/*/.build` |
| Everything worked yesterday, nothing today | VM recycled: images, containers, volumes and processes gone; `$HOME` and `.dev/` kept | Part 2, Part 4 |

### Reading the service log

```bash
make api-logs
grep correlation_id ~/aperture/.dev/aperture.log
grep '"level":"ERROR"' ~/aperture/.dev/aperture.log
```

### Full teardown

```bash
cd ~/aperture
make api-down
make backend-down
docker compose -f infra/docker-compose.yml down -v
rm -rf .dev
```
