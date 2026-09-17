# Phase 3 runbook: setup, run, and verify

Self-contained, for a fresh Cloud Shell session. Every command is copy-and-paste ready.

---

## What Phase 3 actually contains

Read this first, because it determines which of the steps below apply.

| Delivered | Runnable now | Where |
|---|---|---|
| PKCE generation and S256 challenge | **Yes**, automated tests | `ApertureAuth` |
| Token state, expiry, skew handling | **Yes** | `ApertureAuth` |
| Serialized refresh coordination | **Yes**, the centrepiece | `ApertureAuth` |
| Offline grace policy | **Yes** | `ApertureAuth` |
| JWT verification, including attack cases | **Yes** | `backend/internal/authn` |
| Tenant scoping and fail-closed context | **Yes** | `backend/internal/tenancy` |
| Row-level security policies | **Yes, manually**, see Part 7 | `backend/migrations/0001_tenancy.sql` |
| Keychain token storage | No, macOS only | `ApertureSecurity` |
| **Authentication HTTP endpoints** | **No. Phase 6** | |

**There are no auth API endpoints to call yet.** The service serves `/healthz`, `/readyz`,
and `/version` only. Token exchange, device registration, and tenant discovery arrive in
Phase 6 when the database is wired to the service. Any runbook that hands you a
`POST /v1/auth/token` payload today would be describing code that does not exist.

---

## Part 1: verify the existing environment

```bash
cd ~ 2>/dev/null

echo "--- repository ---"
if [ -d ~/aperture/.git ]; then
  cd ~/aperture
  git log --oneline -3
  git status --short | head
  git tag -l
else
  echo "MISSING: ~/aperture is not a git repository"
fi

echo "--- toolchain ---"
for tool in git docker python3 go gh gcloud; do
  printf '%-8s %s\n' "$tool" "$(command -v $tool || echo MISSING)"
done

echo "--- swift ---"
command -v swift >/dev/null && swift --version | head -1 \
  || echo "no local Swift (expected: the container route is used instead)"

echo "--- docker images ---"
docker images --format '{{.Repository}}:{{.Tag}}' | grep -E 'swift|postgres|aperture' || echo "none present"

echo "--- running containers ---"
docker ps --format '{{.Names}}\t{{.Status}}\t{{.Ports}}' || echo "none"

echo "--- docker volumes (database persistence) ---"
docker volume ls --format '{{.Name}}' | grep -i aperture || echo "no aperture volumes"

echo "--- disk ---"
df -h ~ | tail -1
```

Expected on a fresh session: the repository is present because `$HOME` persists, but no
containers are running and the Docker images are gone, because the VM recycled.

---

## Part 2: install or initialize what is missing

### 2.1 Repository, if absent

```bash
cd ~
git clone https://github.com/$(gh api user --jq .login)/aperture.git
cd ~/aperture
chmod +x scripts/*.sh scripts/*.py
```

If it exists, bring it current instead:

```bash
cd ~/aperture && git pull
```

### 2.2 Tooling, if the VM recycled

```bash
cd ~/aperture
source ~/.bashrc
./scripts/cloudshell_setup.sh   # idempotent; skips whatever is already present
make doctor
```

### 2.3 Container images

```bash
docker pull swift:6.3        # about 2 GB, on the ephemeral disk, not your $HOME quota
docker pull postgres:16-alpine
```

### 2.4 Confirm the disk has room

```bash
df -h ~ | tail -1              # Docker images do not count against this
docker system df               # they count against the VM disk, which is larger
```

---

## Part 3: configure environment variables

```bash
cd ~/aperture

[ -f .env ] || cp .env.example .env
cat .env
```

The full set, with the values the runbook assumes:

| Variable | Value | Used by |
|---|---|---|
| `POSTGRES_USER` | `aperture` | Bootstrap role, superuser, migrations and seeding only |
| `POSTGRES_PASSWORD` | `local-development-only` | Local only. Production uses Secret Manager |
| `POSTGRES_DB` | `aperture` | |
| `POSTGRES_PORT` | `5432` | Change if something already holds the port |
| `APERTURE_HTTP_ADDR` | `:8080` | The Go service |
| `APERTURE_LOG_LEVEL` | `debug` | `debug`, `info`, `warn`, `error` |
| `APERTURE_ENVIRONMENT` | `local` | Appears in every structured log line |

There is a second database role the compose file does not mention, created by the grants
migration:

| Role | Password | Attributes | Purpose |
|---|---|---|---|
| `aperture` | `local-development-only` | SUPERUSER | Migrations and seeding. **Bypasses row-level security** |
| `aperture_app` | `local-development-only` | NOSUPERUSER, NOBYPASSRLS | What the application connects as. Subject to every policy |

That distinction is the whole reason Part 7 proves anything. A superuser bypasses row
security regardless of `FORCE ROW LEVEL SECURITY`, so a stack whose application connects as
the bootstrap role appears to isolate tenants while isolating nothing.

---

## Part 4: start the services

```bash
cd ~/aperture
make backend-up
docker compose -f infra/docker-compose.yml ps
```

First run builds the Go image and pulls Postgres, two to four minutes. Later runs are
seconds.

Wait for Postgres to report ready:

```bash
for i in $(seq 1 30); do
  docker compose -f infra/docker-compose.yml exec -T postgres \
    pg_isready -U aperture -d aperture && break
  sleep 1
done
```

---

## Part 5: verify service health

```bash
curl -s localhost:8080/healthz | tee /dev/stderr | grep -q '"status":"ok"' \
  && echo "  healthz OK"

curl -s localhost:8080/readyz | tee /dev/stderr | grep -q '"status":"ready"' \
  && echo "  readyz OK"

curl -s localhost:8080/version
```

Expected:

```json
{"status":"ok","version":"local"}
{"status":"ready"}
{"contract":"v1","environment":"local","version":"local"}
```

Confirm correlation-id propagation, which is the diagnostic backbone for every later phase:

```bash
curl -si -H 'X-Correlation-Id: runbook-check-001' localhost:8080/healthz \
  | grep -i 'x-correlation-id'
```

The header must come back unchanged. Then confirm the server generates one when absent:

```bash
curl -si localhost:8080/healthz | grep -i 'x-correlation-id'
```

And that it appears in the structured log:

```bash
docker compose -f infra/docker-compose.yml logs aperture --tail 5 | grep correlation_id
```

Browser access, through Cloud Shell's authenticated proxy:

```bash
echo "$(cloudshell get-web-preview-url -p 8080)/healthz"
echo "$(cloudshell get-web-preview-url -p 8080)/version"
```

**The Web Preview button opens `/`, and there is no route there.** That returns a 404 in
the standard error envelope, which is correct rather than broken: a service with no product
surface yet should not invent a root page, and listing the available routes would be a small
information disclosure for the sake of one line in a runbook. Append the path, as above.

A 404 from the preview is itself a useful signal. It means the container is running and the
proxy reaches it. A connection error or a 502 would mean something quite different.

---

## Part 6: run the Phase 3 test suites

### 6.1 Static checks, no toolchain required

```bash
cd ~/aperture
make check
```

Expect module boundaries OK, thirteen queue-schema assertions, configuration OK, and the
golangci-lint schema alignment line.

### 6.2 Swift, in the container

```bash
make core-test-docker
```

First run resolves `swift-crypto`, which needs network and takes an extra minute or two.

Expect roughly 115 tests across 20 suites. The Phase 3 additions are the suites named
**PKCE**, **Session policy**, **Token refresh coordination**, and **Token state**.

### 6.3 Go

```bash
make backend-test
```

Runs with the race detector. Expect the `authn` and `tenancy` packages to pass.

To watch the individual scenarios rather than a summary:

```bash
cd ~/aperture/backend
go test ./internal/authn/... -v -run TestVerify
go test ./internal/tenancy/... -v
cd ~/aperture
```

---

## Part 7: database scenarios with seed data

This is the part that exercises code no automated suite covers yet: the row-level security
policies. They are written but have never been executed, so this is also their first test.

### 7.1 Inspect the current state

```bash
make db-status
```

On a fresh volume: no tables, no application role, no seed data.

### 7.2 Apply migrations and grants

```bash
make db-migrate
```

Applies every file in `backend/migrations/` and `infra/db/` in order, recording each in a
`schema_migrations` table with its checksum. Re-running is a no-op: applied files are
skipped by name, and a file whose contents changed since it ran is a hard error rather than
a silent re-application. A migration is history, not source, so an edit after the fact
produces a database whose schema does not match its own record, and the difference stays
invisible until a fresh environment is built from the same files and behaves differently.

**If your database was created before migration tracking existed**, adopt it rather than
re-running anything:

```bash
make db-baseline    # records the files as applied, without executing them
make db-migrate     # now a no-op
```

### 7.3 Seed the fixtures

```bash
make db-seed
make db-status
```

Expect `tenants=2 users=4 devices=3 audit=2`.

### 7.4 The seed data, in full

Every identifier is fixed, so the commands below can reference them literally.

**Tenants**

| Field | Tenant A | Tenant B |
|---|---|---|
| id | `11111111-1111-4111-a111-111111111111` | `22222222-2222-4222-a222-222222222222` |
| name | Northwind Mutual | Pacific Grid Utilities |
| email_domain | `northwind-mutual.example` | `pacific-grid.example` |
| retention_years | 7 | 15 |
| media_upload_policy | `required_only` | `none` |
| oidc_issuer | `https://northwind.okta.example/oauth2/default` | `https://pacificgrid.entra.example/v2.0` |
| oidc_client_id | `0oaNORTHWIND01` | `0oaPACIFICGRID1` |

**Users**

| id | tenant | email | roles | status |
|---|---|---|---|---|
| `a1111111-1111-4111-a111-111111111111` | A | dana.reyes@northwind-mutual.example | inspector | active |
| `a2222222-2222-4222-a222-222222222222` | A | priya.shah@northwind-mutual.example | reviewer, admin | active |
| `b1111111-1111-4111-a111-111111111111` | B | marcus.obi@pacific-grid.example | inspector | active |
| `b2222222-2222-4222-a222-222222222222` | B | sam.whitfield@pacific-grid.example | inspector | suspended |

**Devices**

| id | tenant | model | tier | attestation |
|---|---|---|---|---|
| `d1111111-1111-4111-a111-111111111111` | A | iPhone15,3 | A | verified |
| `d2222222-2222-4222-a222-222222222222` | B | iPhone12,1 | C | verified |
| `d3333333-3333-4333-a333-333333333333` | B | iPhone14,7 | B | failed |

**Refresh token families.** Only hashes are stored. The digests correspond to the literal
strings `dev-refresh-token-dana-gen0` and `dev-refresh-token-marcus-gen0`, which is what
lets you demonstrate rotation without inventing a token format.

### 7.5 Verify tenant isolation

```bash
make db-verify
```

Seven assertions, all executed as `aperture_app`:

| Scenario | Expected |
|---|---|
| Scope to tenant A, count users | 2 |
| Scope to tenant B, count users | 2 |
| **No scope set at all, count users** | **0, failing closed** |
| Scope to A, ask for a tenant B user by primary key | 0 rows |
| Scope to A, insert an audit row attributed to B | rejected by `WITH CHECK` |
| `UPDATE audit_log` | permission denied |
| `DELETE FROM audit_log` | permission denied |

The third is the one that matters most. A policy that fails open is worse than no policy,
because it looks like protection.

### 7.6 Run the scenarios by hand

To see the mechanism rather than the summary:

```bash
make db-psql
```

Then, inside psql:

```sql
-- As the bootstrap superuser, row security is bypassed entirely. This is why the
-- application must never connect with this role.
SELECT count(*) FROM users;                       -- 4: every tenant, no filter

\q
```

Now as the application role:

```bash
./scripts/db.sh app-psql
```

```sql
-- No scope: the policy has nothing to match, so nothing is visible.
SELECT count(*) FROM users;                       -- 0

-- Scoped. is_local = true confines the setting to this transaction, so a pooled
-- connection cannot carry one tenant's scope into another tenant's request.
BEGIN;
SELECT set_config('app.tenant_id', '11111111-1111-4111-a111-111111111111', true);
SELECT email FROM users ORDER BY email;           -- both Northwind users
SELECT count(*) FROM users
  WHERE id = 'b1111111-1111-4111-a111-111111111111';   -- 0, the row is invisible
COMMIT;

-- Outside the transaction the scope is gone again.
SELECT count(*) FROM users;                       -- 0

-- Attempt to write into another tenant.
BEGIN;
SELECT set_config('app.tenant_id', '11111111-1111-4111-a111-111111111111', true);
INSERT INTO audit_log (tenant_id, entity_type, action)
VALUES ('22222222-2222-4222-a222-222222222222', 'device', 'forged');
-- ERROR: new row violates row-level security policy for table "audit_log"
ROLLBACK;

-- Append-only, as a grant rather than a convention.
UPDATE audit_log SET action = 'rewritten';        -- ERROR: permission denied
DELETE FROM audit_log;                            -- ERROR: permission denied

\q
```

### 7.7 Reset to a known state

```bash
make db-reset      # destroys the volume, rebuilds, migrates, seeds
```

---

## Part 8: verify the expected results

A complete Phase 3 pass:

```bash
cd ~/aperture
make check          && echo "1/5 static checks"
make core-test-docker && echo "2/5 swift"
make backend-test   && echo "3/5 go"
curl -sf localhost:8080/readyz >/dev/null && echo "4/5 service healthy"
make db-verify      && echo "5/5 tenant isolation"
```

| Check | Expected |
|---|---|
| `make check` | boundaries OK, 13 schema assertions, configuration OK |
| `make core-test-docker` | ~115 tests, 20 suites, 0 failures |
| `make backend-test` | `ok` for `internal/authn` and `internal/tenancy` |
| `/readyz` | `{"status":"ready"}` |
| `make db-verify` | 7 passes, "Tenant isolation verified" |

The four Phase 3 Swift suites specifically:

```bash
make core-shell-docker
# inside the container:
swift test --filter "PKCE"
swift test --filter "Session policy"
swift test --filter "Token refresh coordination"
exit
```

---

## Part 9: troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| `swift: command not found` | VM recycled | `source ~/.bashrc`, or use `make core-test-docker` |
| `docker: command not found` | VM still booting | Wait 30 seconds and retry |
| `swift-crypto` fetch fails | No network in the container, or a proxy | `docker run --rm swift:6.3 curl -sI https://github.com` to confirm egress |
| `make core-test-docker` cannot write `.build` | Ownership mismatch from an earlier root-run container | `sudo chown -R $(id -u):$(id -g) ios/Packages/ApertureCore/.build` |
| `port is already allocated` on 5432 | Another Postgres running | `docker ps`, stop it, or set `POSTGRES_PORT=5433` in `.env` |
| `port is already allocated` on 8080 | Another service | Change the mapping in `infra/docker-compose.yml` |
| `connection refused` on `localhost:8080` | Service still starting | `docker compose -f infra/docker-compose.yml logs aperture` |
| `404 page not found` at the Web Preview root | No route at `/`, which is expected | Append `/healthz`. A 404 proves the service is reachable |
| A 502 or a connection error from the preview | The container is not running | `make backend-up`, then check `docker compose ps` |
| `/readyz` returns 503 | Startup incomplete | Normal for the first second. Persistent means check the logs |
| `psql: FATAL: role "aperture_app" does not exist` | Grants not applied | `make db-migrate` |
| `db-verify` reports tenant A sees 4 users | Connected as a superuser | The script uses `aperture_app` deliberately; confirm with `\du` in psql |
| `db-verify` reports 0 for both tenants | Seed missing | `make db-seed` |
| `permission denied for table users` | Grants missing | `make db-migrate` |
| `db-migrate` fails with `relation "tenants" already exists` | Schema predates migration tracking | `make db-baseline`, then `make db-migrate` |
| `db-migrate` reports a file was edited after it was applied | A migration was changed after running | Write a new migration, or `make db-reset` to rebuild |
| Migration fails on `CREATE EXTENSION` | Image lacks the extension | `postgres:16-alpine` has both `pgcrypto` and `citext`; confirm the image tag |
| Everything worked yesterday, nothing today | VM recycled: images and containers are gone, `$HOME` is not | Part 2, then Part 4 |
| Database empty after a restart | The volume was pruned | `make db-reset` |
| `go: command not found` | PATH not reloaded | `source ~/.bashrc` |
| Go tests fail to build | Module cache | `cd backend && go clean -modcache && go mod download` |

### Full teardown

```bash
cd ~/aperture
make backend-down
docker compose -f infra/docker-compose.yml down -v   # also destroys the database volume
docker system prune -af                              # reclaims the VM disk, not $HOME
```
