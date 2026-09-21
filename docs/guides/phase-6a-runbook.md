# Phase 6a runbook: setup, run, and verify

Self-contained, for a fresh Cloud Shell session.

---

## What Phase 6a contains

The first phase with a real API surface. Everything below is exercisable over HTTP.

| Delivered | Runnable now | Where |
|---|---|---|
| `GET /v1/sync/changes`, cursor-paged | **Yes** | `internal/httpapi` |
| `POST /v1/sync/deltas`, batched | **Yes** | `internal/httpapi` |
| `GET /v1/me` | **Yes** | `internal/httpapi` |
| Bearer token verification against a key set | **Yes** | `internal/authn` |
| JWKS caching with stale-key fallback | **Yes** | `internal/authn` |
| Per-field conflict detection | **Yes** | `internal/syncapi` |
| Tenant-scoped idempotency | **Yes** | `internal/syncapi` |
| Minimum client version gate | **Yes** | `internal/httpapi` |
| Development token minting | **Yes** | `cmd/devtoken` |
| **PostgreSQL-backed store** | **No, Phase 6b** | |

**The store is in-memory.** It sits behind the `Store` interface so the protocol logic
could be finished and tested before persistence existed; the PostgreSQL implementation
replaces one line in `main.go`. State is lost on restart, which is why the scenarios below
mint and push in one session.

The Postgres container from Phase 3 is still needed only for the row-level security
regression in Part 7.8. Phase 6a does not read from it.

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
for tool in git go docker python3 curl gh; do
  printf '%-8s %s\n' "$tool" "$(command -v $tool || echo MISSING)"
done
go version 2>/dev/null || echo "Go is required for this phase"

echo "--- local API artifacts ---"
ls -la ~/aperture/.dev 2>/dev/null || echo "no .dev directory yet (make api-keygen creates it)"

echo "--- is anything already on port 8080 ---"
curl -sf http://localhost:8080/healthz && echo "  something is already serving" || echo "  port is free"

echo "--- containers and volumes (neither survives a VM recycle) ---"
docker ps --format '{{.Names}}\t{{.Status}}' || echo "none running"
docker volume ls --format '{{.Name}}' | grep -i aperture || echo "no database volume"

echo "--- archive ---"
ls -la ~/aperture-phase-6a.zip 2>/dev/null && md5sum ~/aperture-phase-6a.zip
echo "  compare against the MD5 published with the archive"
```

`$HOME` persists across a VM recycle. Docker images, containers, and volumes do not, and
neither does anything running. `.dev/` lives under `$HOME`, so the signing key survives.

---

## Part 2: install or initialize what is missing

```bash
cd ~/aperture
source ~/.bashrc
./scripts/cloudshell_setup.sh      # idempotent
make doctor
```

Go is the only toolchain this phase needs, and Cloud Shell ships it. Docker is needed only
for the Swift suites and the Postgres regression.

Apply the archive after verifying it. **No files were deleted in Phase 6a:**

```bash
cd ~
md5sum aperture-phase-6a.zip
unzip -oq aperture-phase-6a.zip
cd ~/aperture && chmod +x scripts/*.sh scripts/*.py
```

---

## Part 3: configure environment variables

Phase 6a adds five. The service refuses to mount the sync endpoints unless `APERTURE_JWKS_PATH`
is set, which is deliberate: an endpoint that silently falls back to no verification when
configuration is missing is a production incident waiting for one bad deploy, and the
failure is invisible because the service looks healthy and answers every request.

| Variable | Default | Purpose |
|---|---|---|
| `APERTURE_JWKS_PATH` | *(empty)* | Key set for token verification. **Empty disables the sync endpoints** |
| `APERTURE_TOKEN_ISSUER` | `https://dev.aperture.local` | Required `iss` claim |
| `APERTURE_TOKEN_AUDIENCE` | `aperture-api` | Required `aud` claim |
| `APERTURE_MINIMUM_CLIENT_VERSION` | `0.1.0` | Clients below this receive 426 |
| `APERTURE_HTTP_ADDR` | `:8080` | Listen address |
| `APERTURE_LOG_LEVEL` | `info` | `debug` for the scenarios below |
| `APERTURE_ENVIRONMENT` | `local` | Appears in every log line |

Carried over from Phase 3, used only by the Postgres regression:

| Variable | Value |
|---|---|
| `POSTGRES_USER` | `aperture` |
| `POSTGRES_PASSWORD` | `local-development-only` |
| `POSTGRES_DB` | `aperture` |
| `POSTGRES_PORT` | `5432` |

Database roles, unchanged:

| Role | Attributes |
|---|---|
| `aperture` | SUPERUSER, bypasses row security. Migrations and seeding only |
| `aperture_app` | NOSUPERUSER, NOBYPASSRLS. Subject to every policy |

`make api-up` sets the API variables for you; nothing needs to go in your shell profile.

---

## Part 4: start the service

```bash
cd ~/aperture
make api-up
```

That builds both binaries, generates a signing key and its key set under `.dev/`, starts the
service in the background, and waits for it to answer.

**On the signing key.** The tempting shortcut for local development is a mode where the
service trusts an `X-Tenant-Id` header when the environment is `local`. That is wrong twice
over: the authentication code then carries a branch never exercised until production, and a
development affordance that trusts a client-supplied tenant is one merge away from becoming
the production behaviour. Here the service verifies a real RS256 signature against a real
key set. Only the key is local, and `.dev/` is gitignored because a key that signs tokens
the service accepts is a credential even when it is only yours.

Optional, for the Part 7.8 regression only:

```bash
make backend-up
make db-migrate && make db-seed
```

Stop the service when finished:

```bash
make api-down
```

---

## Part 5: verify service health

```bash
curl -s localhost:8080/healthz    # {"status":"ok","version":"dev"}
curl -s localhost:8080/readyz     # {"status":"ready"}
curl -s localhost:8080/version

# An unmatched route returns the contract error envelope, not plain text
curl -s localhost:8080/nope | python3 -m json.tool

# A correlation identifier is echoed unchanged
curl -si -H 'X-Correlation-Id: phase6-001' localhost:8080/healthz | grep -i correlation
```

Confirm the sync endpoints actually mounted:

```bash
grep "sync endpoints" ~/aperture/.dev/aperture.log
```

You want `sync endpoints mounted`. If it says `sync endpoints disabled`, `APERTURE_JWKS_PATH`
was not set and every `/v1/` route will return 404.

Browser access:

```bash
echo "$(cloudshell get-web-preview-url -p 8080)/healthz"
```

The preview button opens `/`, which has no route and correctly returns a 404 envelope.

---

## Part 6: run the Phase 6a suites

```bash
cd ~/aperture

make check           # boundaries, queue schema, configuration
make backend-test    # Go, with the race detector
make api-scenarios   # every endpoint, against the running service
```

`make backend-test` covers `syncapi`, `httpapi`, `authn`, `tenancy`, `httpx`, and
`cmd/aperture`. `make api-scenarios` is the end-to-end pass and is what Part 7 documents.

The Swift suites are unchanged by this phase:

```bash
make core-test-docker
```

---

## Part 7: test scenarios with inputs and expected results

Every scenario below runs automatically in `make api-scenarios`. They are written out so
you can run them individually and read the payloads.

### 7.1 Dummy values

| Name | Value |
|---|---|
| Tenant A, Northwind Mutual | `11111111-1111-4111-a111-111111111111` |
| Tenant B, Pacific Grid Utilities | `22222222-2222-4222-a222-222222222222` |
| Dana Reyes, inspector, tenant A | subject `00uDANA0001` |
| Priya Shah, reviewer and admin, tenant A | subject `00uPRIYA001` |
| Marcus Obi, inspector, tenant B | subject `00uMARCUS01` |
| Issuer | `https://dev.aperture.local` |
| Audience | `aperture-api` |
| Signing key | `.dev/dev-key.pem` |
| Key set | `.dev/dev-jwks.json` |

Mint tokens:

```bash
cd ~/aperture
TOKEN_A=$(make -s api-token TENANT=11111111-1111-4111-a111-111111111111 SUBJECT=00uDANA0001)
TOKEN_B=$(make -s api-token TENANT=22222222-2222-4222-a222-222222222222 SUBJECT=00uMARCUS01)
echo "${TOKEN_A:0:40}..."
```

### 7.2 Authentication

```bash
# No token
curl -s -o /dev/null -w '%{http_code}\n' localhost:8080/v1/me                       # 401

# Malformed token
curl -s -o /dev/null -w '%{http_code}\n' -H "Authorization: Bearer nonsense" \
  localhost:8080/v1/me                                                              # 401

# Tampered signature: same token, last character changed
curl -s -o /dev/null -w '%{http_code}\n' -H "Authorization: Bearer ${TOKEN_A%?}X" \
  localhost:8080/v1/me                                                              # 401

# Expired token
EXPIRED=$(.dev/devtoken mint -key .dev/dev-key.pem \
  -tenant 11111111-1111-4111-a111-111111111111 -subject 00uDANA0001 -ttl -5m)
curl -s -o /dev/null -w '%{http_code}\n' -H "Authorization: Bearer $EXPIRED" \
  localhost:8080/v1/me                                                              # 401

# Valid token
curl -s -H "Authorization: Bearer $TOKEN_A" localhost:8080/v1/me | python3 -m json.tool
```

Expected for the last one:

```json
{
    "tenant_id": "11111111-1111-4111-a111-111111111111",
    "roles": ["inspector"],
    "user_id": "00uDANA0001"
}
```

The tenant comes from the signed token and from nowhere else. There is an
`X-Aperture-Tenant-Id` header in the logs for correlation, and it never influences an
authorization decision, because a header is trivially forged.

### 7.3 Push: apply, replay, conflict

```bash
FINDING="f-demo-1"

# Create
curl -s -X POST localhost:8080/v1/sync/deltas \
  -H "Authorization: Bearer $TOKEN_A" -H 'Content-Type: application/json' \
  -d "{\"operations\":[{
        \"operation_id\":\"op-1\",\"entity_type\":\"finding\",\"entity_id\":\"$FINDING\",
        \"kind\":\"create\",\"dirty_fields\":[\"note\"],\"base_version\":0,
        \"hlc\":\"2026-09-10T00:26:40.123Z-0000-devA\",
        \"payload\":{\"note\":\"Hail bruising on the south slope.\"}}]}" | python3 -m json.tool
```

Expected: `{"results":[{"operation_id":"op-1","status":"applied","server_version":1}]}`

```bash
# Send the identical request again
```

Expected: `"status":"replayed"`, same `server_version`. Exactly-once effect over an
at-least-once channel, which is what makes a retry after an unknown outcome safe.

```bash
# A second actor edits a DIFFERENT field, still believing version 0
curl -s -X POST localhost:8080/v1/sync/deltas \
  -H "Authorization: Bearer $TOKEN_A" -H 'Content-Type: application/json' \
  -d "{\"operations\":[{
        \"operation_id\":\"op-2\",\"entity_type\":\"finding\",\"entity_id\":\"$FINDING\",
        \"kind\":\"update\",\"dirty_fields\":[\"severity\"],\"base_version\":0,
        \"hlc\":\"2026-09-10T00:27:00.000Z-0000-devB\",
        \"payload\":{\"severity\":\"major\"}}]}" | python3 -m json.tool
```

Expected: `"status":"applied"`. A version mismatch alone is **not** a conflict. Two actors
editing different fields of one record is concurrency, not disagreement, and prompting a
person for it would happen several times a shift for nothing.

```bash
# Now a second actor edits the SAME field, still at version 0
curl -s -X POST localhost:8080/v1/sync/deltas \
  -H "Authorization: Bearer $TOKEN_A" -H 'Content-Type: application/json' \
  -d "{\"operations\":[{
        \"operation_id\":\"op-3\",\"entity_type\":\"finding\",\"entity_id\":\"$FINDING\",
        \"kind\":\"update\",\"dirty_fields\":[\"note\"],\"base_version\":0,
        \"hlc\":\"2026-09-10T00:28:00.000Z-0000-devB\",
        \"payload\":{\"note\":\"Contradicting observation.\"}}]}" | python3 -m json.tool
```

Expected:

```json
{"results":[{"operation_id":"op-3","status":"conflict","server_version":2,
             "conflicting_fields":["note"]}]}
```

Neither value is discarded. The client surfaces it for a person to decide, and the
inspection cannot be submitted until they do.

### 7.4 Validation

```bash
# Empty batch
curl -s -o /dev/null -w '%{http_code}\n' -X POST localhost:8080/v1/sync/deltas \
  -H "Authorization: Bearer $TOKEN_A" -H 'Content-Type: application/json' \
  -d '{"operations":[]}'                                                            # 400

# Unknown field
curl -s -X POST localhost:8080/v1/sync/deltas \
  -H "Authorization: Bearer $TOKEN_A" -H 'Content-Type: application/json' \
  -d '{"operations":[{"operation_id":"op-x","entity_type":"finding","entity_id":"f-x",
       "kind":"create","dirty_fields":["note"],"hlc":"h","surprise":"value"}]}'      # 400

# Missing dirty_fields
curl -s -X POST localhost:8080/v1/sync/deltas \
  -H "Authorization: Bearer $TOKEN_A" -H 'Content-Type: application/json' \
  -d '{"operations":[{"operation_id":"op-y","entity_type":"finding","entity_id":"f-y",
       "kind":"update","base_version":0,"hlc":"h"}]}' | python3 -m json.tool
```

The unknown field is rejected rather than ignored: a client sending a field the server does
not understand believes something is being recorded that is not, and silently discarding it
is how a protocol drifts without anyone noticing.

The missing `dirty_fields` case returns `"status":"rejected"` with `"retryable":false`.
Without dirty fields the server can only compare versions, and every concurrent edit becomes
a whole-entity conflict that clobbers a field the sender never touched.

### 7.5 A batch with mixed outcomes

```bash
curl -s -X POST localhost:8080/v1/sync/deltas \
  -H "Authorization: Bearer $TOKEN_A" -H 'Content-Type: application/json' \
  -d '{"operations":[
       {"operation_id":"b-1","entity_type":"finding","entity_id":"f-b1","kind":"create",
        "dirty_fields":["note"],"base_version":0,"hlc":"h","payload":{"note":"a"}},
       {"operation_id":"b-2","entity_type":"finding","entity_id":"f-b2","kind":"nonsense",
        "dirty_fields":["note"],"hlc":"h"},
       {"operation_id":"b-3","entity_type":"finding","entity_id":"f-b3","kind":"create",
        "dirty_fields":["note"],"base_version":0,"hlc":"h","payload":{"note":"b"}}
      ]}' | python3 -m json.tool
```

Expected: `applied`, `rejected`, `applied`. One poisoned operation must not fail the batch,
or a device with a single bad record cannot sync anything at all, and the user has no way to
identify or remove it.

### 7.6 Pull and cursors

```bash
curl -s -H "Authorization: Bearer $TOKEN_A" \
  "localhost:8080/v1/sync/changes?limit=2" | python3 -m json.tool
```

Expected: two changes, a `next_cursor`, and `"has_more": true`. `has_more` is explicit
rather than inferred from a short page, because an exactly-page-sized final batch would
otherwise be indistinguishable from a full one and the client either stops early or makes a
pointless round trip on a metered connection.

```bash
CURSOR=$(curl -s -H "Authorization: Bearer $TOKEN_A" \
  "localhost:8080/v1/sync/changes?limit=2" | python3 -c "import json,sys; print(json.load(sys.stdin)['next_cursor'])")

curl -s -H "Authorization: Bearer $TOKEN_A" \
  "localhost:8080/v1/sync/changes?cursor=$CURSOR&limit=2" | python3 -m json.tool

# A cursor past the end is not an error
curl -s -o /dev/null -w '%{http_code}\n' -H "Authorization: Bearer $TOKEN_A" \
  "localhost:8080/v1/sync/changes?cursor=99999"                                     # 200

# A malformed cursor is
curl -s -o /dev/null -w '%{http_code}\n' -H "Authorization: Bearer $TOKEN_A" \
  "localhost:8080/v1/sync/changes?cursor=not-a-cursor"                              # 400
```

A cursor past the end happens after a restore from backup. Treated as "nothing new" so the
device recovers on the next change rather than being stuck reporting an error it cannot act on.

### 7.7 Tenant isolation over HTTP

The scenario most worth running by hand.

```bash
# Tenant A has pushed several changes above. Tenant B asks for changes:
curl -s -H "Authorization: Bearer $TOKEN_B" \
  localhost:8080/v1/sync/changes | python3 -m json.tool
```

Expected: `{"changes": [], "next_cursor": "0", "has_more": false}`. None of tenant A's work
is visible, and the response does not hint that anything exists.

```bash
# Tenant B reuses an operation id tenant A already used
curl -s -X POST localhost:8080/v1/sync/deltas \
  -H "Authorization: Bearer $TOKEN_B" -H 'Content-Type: application/json' \
  -d "{\"operations\":[{
        \"operation_id\":\"op-1\",\"entity_type\":\"finding\",\"entity_id\":\"$FINDING\",
        \"kind\":\"create\",\"dirty_fields\":[\"note\"],\"base_version\":0,
        \"hlc\":\"h\",\"payload\":{\"note\":\"tenant B work\"}}]}" | python3 -m json.tool
```

Expected: `"status":"applied"`, not `"replayed"`. A globally keyed idempotency table would
have returned tenant A's stored response to tenant B, which is both a correctness failure
and a cross-tenant disclosure.

### 7.8 Client version gate

```bash
curl -s -o /dev/null -w '%{http_code}\n' -H "Authorization: Bearer $TOKEN_A" \
  -H 'X-Aperture-Client-Version: 0.0.1' localhost:8080/v1/me                        # 426

curl -s -H "Authorization: Bearer $TOKEN_A" \
  -H 'X-Aperture-Client-Version: 0.0.1' localhost:8080/v1/me | python3 -m json.tool
```

The 426 body names the minimum version in `details.minimum_version`, so the app can tell the
user what to do rather than showing a generic error. The gate runs **before** authentication,
so an unsupported client gets a specific answer rather than a token error that would send
the user to reinstall.

### 7.9 Phase 3 regression, database

Unchanged by Phase 6a. Needs the Postgres container.

```bash
make backend-up
make db-status     # 2 of 2 migrations; tenants=2 users=4 devices=3
make db-verify     # 8 isolation checks
make db-reset      # if the volume is gone
```

---

## Part 8: verify the expected results

```bash
cd ~/aperture
make check              && echo "1/6 static checks"
make backend-test       && echo "2/6 go suites"
make api-up             && echo "3/6 service running"
make api-scenarios      && echo "4/6 api scenarios"
make core-test-docker   && echo "5/6 swift suites"
make db-verify          && echo "6/6 tenant isolation in the database"
```

| Check | Expected |
|---|---|
| `make check` | boundaries OK, 13 schema assertions, configuration OK |
| `make backend-test` | `ok` for syncapi, httpapi, authn, tenancy, httpx, cmd/aperture |
| `make api-scenarios` | 21 passes, "All API scenarios passed" |
| `make core-test-docker` | ~194 tests, 30 suites, 0 failures |
| `make db-verify` | 8 passes |

---

## Part 9: troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| Archive MD5 does not match | Stale download; the browser kept an earlier copy | Re-download, re-upload, verify before extracting |
| Every `/v1/` route returns 404 | `APERTURE_JWKS_PATH` unset, so the sync endpoints never mounted | `make api-up`, then `grep "sync endpoints" .dev/aperture.log` |
| All requests return 401 with a fresh token | The service cached a key set that no longer matches the signing key | `make api-down && make api-up`. The scenario script detects this before running and prints both key ids |
| Invalid tokens are refused correctly but valid ones are too | Same cause. Correct rejections are not evidence that verification is working | Compare the `kid` in the token header with the one in `.dev/dev-jwks.json` |
| 401 with a token that worked a minute ago | Default lifetime is 15 minutes | Mint a fresh one with `make api-token` |
| `devtoken: reading key: no such file` | Key not generated yet | `make api-keygen` |
| `make api-up` says the port is in use | An earlier service is still running | `make api-down`, or `lsof -i :8080` |
| Data disappeared after a restart | The store is in-memory until Phase 6b | Expected. Re-push in the same session |
| `make api-scenarios` cannot reach the service | Not running, or a different port | `make api-up`, or set `BASE_URL` |
| Scenario failures after a restart | Earlier scenario state is gone | Re-run: every scenario creates its own entities |
| 426 on every request | A stale `X-Aperture-Client-Version` header in your shell history | Omit the header, or send a current version |
| `go: command not found` | PATH not reloaded after a recycle | `source ~/.bashrc` |
| Go tests fail to build | Module cache | `cd backend && go clean -modcache && go mod download` |
| `db-status` shows no tables | Volume gone: recycle, `down -v`, or a prune | `make db-migrate && make db-seed` |
| Everything worked yesterday, nothing today | VM recycled: images, containers, volumes and processes gone; `$HOME` and `.dev/` kept | Part 2, `make api-up`, and `make db-migrate && make db-seed` if using the database |

### Reading the service log

```bash
make api-logs                                    # tail
grep correlation_id ~/aperture/.dev/aperture.log # join a request to its log lines
grep '"level":"ERROR"' ~/aperture/.dev/aperture.log
```

Token rejection reasons are logged and never returned. Telling a caller whether a token
failed on signature, expiry, or audience is a probing oracle, and none of those distinctions
changes what a legitimate client does next.

### Full teardown

```bash
cd ~/aperture
make api-down
make backend-down
docker compose -f infra/docker-compose.yml down -v
rm -rf .dev
```
