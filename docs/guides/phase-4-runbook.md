# Phase 4a runbook: setup, run, and verify

Self-contained, for a fresh Cloud Shell session.

---

## What Phase 4a contains, and what it does not

| Delivered | Runnable now | Where |
|---|---|---|
| Template condition language, depth-bounded | **Yes** | `ApertureDomain` |
| Template engine: visibility, requirement, gaps | **Yes** | `ApertureDomain` |
| Authoring-time template validation | **Yes** | `ApertureDomain` |
| Capture state machine | **Yes** | `ApertureDomain` |
| Durable capture sequence with rollback | **Yes** | `ApertureDomain/UseCases` |
| Storage and thermal policy | **Yes** | `ApertureDomain` |
| Interactive scenario tool | **Yes** | `ApertureScenarios` |
| `AVCaptureSession` bridge, RoomPlan | No, Phase 4b, macOS | |
| SwiftUI capture and form views | No, Phase 4b, macOS | |

**Phase 4a adds no backend code.** No Go files, no migrations, no endpoints, no seed data.
The Go service, the database schema, and the row-level security policies are exactly as
Phase 3 left them. Sections below that concern the backend are therefore Phase 3 regression
checks, not new work, and they are marked as such.

There are no API payloads for this phase because there is no new API surface. What replaces
them is the scenario tool: the template engine takes JSON input and reports what it decides,
which is the same shape of interaction an endpoint would offer.

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
docker volume ls --format '{{.Name}}' | grep -i aperture || echo "no aperture volume: rebuild with make db-reset"

echo "--- archive integrity ---"
ls -la ~/aperture-phase-4a.zip 2>/dev/null && md5sum ~/aperture-phase-4a.zip
echo "  compare against the MD5 published with the archive"
```

Expected on a fresh session: the repository is present because `$HOME` persists, and
everything Docker holds is gone.

**Docker volumes do not survive a VM recycle.** They live on the VM's ephemeral disk, which
is the same fact that keeps container images off your 5 GB `$HOME` quota. The database is
therefore disposable by design: it holds only seed fixtures, and rebuilding it takes about
thirty seconds. Nothing of value should ever live only in that volume.

---

## Part 2: install or initialize what is missing

```bash
cd ~/aperture

# Tooling, if the VM recycled. Idempotent.
source ~/.bashrc
./scripts/cloudshell_setup.sh
make doctor

# Images
docker pull swift:6.3
docker pull postgres:16-alpine
```

Apply the Phase 4a archive, after verifying it:

A checksum printed inside an archive can never describe the archive containing it, so the
value is published alongside the download rather than here. Compare before extracting:

```bash
cd ~
md5sum aperture-phase-4a.zip     # compare with the published value
unzip -oq aperture-phase-4a.zip
cd ~/aperture
chmod +x scripts/*.sh scripts/*.py
```

**No files were deleted in Phase 4a**, so a plain overlay is complete. When a phase does
delete files, the release notes say so and `unzip -o` alone is not enough, because it
overwrites but never removes.

---

## Part 3: environment variables

Unchanged from Phase 3. Nothing in Phase 4a reads configuration.

```bash
cd ~/aperture
[ -f .env ] || cp .env.example .env
cat .env
```

| Variable | Value | Used by |
|---|---|---|
| `POSTGRES_USER` | `aperture` | Bootstrap role, superuser, migrations only |
| `POSTGRES_PASSWORD` | `local-development-only` | Local only |
| `POSTGRES_DB` | `aperture` | |
| `POSTGRES_PORT` | `5432` | |
| `APERTURE_HTTP_ADDR` | `:8080` | Go service |
| `APERTURE_LOG_LEVEL` | `debug` | |
| `APERTURE_ENVIRONMENT` | `local` | |

Database roles, also unchanged:

| Role | Password | Attributes | Purpose |
|---|---|---|---|
| `aperture` | `local-development-only` | SUPERUSER | Migrations and seeding. Bypasses row security |
| `aperture_app` | `local-development-only` | NOSUPERUSER, NOBYPASSRLS | Subject to every policy |

---

## Part 4: start the services

Only needed for the Phase 3 regression checks in Part 7.4. Phase 4a itself requires nothing
running.

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
curl -s localhost:8080/version    # {"contract":"v1","environment":"local","version":"local"}

# The catch-all returns the contract envelope rather than plain text
curl -s localhost:8080/no-such-route | python3 -m json.tool

# Correlation id echoed back
curl -si -H 'X-Correlation-Id: phase4-check-001' localhost:8080/healthz | grep -i correlation
```

The Web Preview button opens `/`, where there is no route. That returns a 404 in the error
envelope, which is correct. Append a path:

```bash
echo "$(cloudshell get-web-preview-url -p 8080)/healthz"
```

---

## Part 6: run the Phase 4a suites

```bash
cd ~/aperture

make check              # boundaries, queue schema, configuration. No toolchain needed
make core-test-docker   # every Swift suite
make backend-test       # Phase 3 regression, unchanged by this phase
```

Expect roughly 145 tests across 24 suites. The Phase 4a additions are the suites named
**Template engine**, **Template conditions**, **Capture durability**, **Capture state
machine**, and **Device conditions**.

Run one suite at a time:

```bash
cd ~/aperture
make suites                       # every suite, with the identifier --filter matches
make core-test-filter FILTER="TemplateEngineTests"
make core-test-filter FILTER="CaptureMediaTests"
make core-test-filter FILTER="CaptureStateTests"
```

**`--filter` matches the Swift type name, not the `@Suite` display string.** "Capture
durability" is `CaptureMediaTests`. A filter matching nothing exits successfully with
"No matching test cases were run", which reads like a pass.

---

## Part 7: test scenarios with inputs and expected results

### 7.1 The fixture template

Every scenario below uses one template, a residential hail roof inspection. Print it:

```bash
cd ~/aperture
make scenario ARGS="fields"
```

| Field key | Kind | Visible when | Required when |
|---|---|---|---|
| `roof_material` | choice: `asphalt_shingle`, `tile`, `metal`, `other` | always | always |
| `roof_material_other` | text, max 120 | `roof_material == other` | `roof_material == other` |
| `slope_degrees` | number, 0 to 90 | always | always |
| `fall_protection_used` | boolean | `slope_degrees > 30` | `slope_degrees > 30` |
| `access_notes` | multiline text, max 2000 | always | never |

| Capture requirement | Count | Condition |
|---|---|---|
| `elevation_photos` | 4 photos | always |
| `damage_closeups` | 2 photos | `roof_material == asphalt_shingle` |

### 7.2 Template engine scenarios

Each runs the engine against the values given and prints visible fields, required keys,
outstanding captures, and what blocks submission.

**Scenario A: nothing answered yet.**

```bash
make scenario ARGS="template '{}'"
```

Expected: `roof_material_other` and `fall_protection_used` are **not** visible. Required is
`roof_material` and `slope_degrees`. Blocking includes both of those plus
`elevation_photos`. Every gap is reported at once, never one at a time.

**Scenario B: the conditional field appears.**

```bash
make scenario ARGS="template '{\"roof_material\":\"other\"}'"
```

Expected: `roof_material_other` becomes visible **and** required. `fall_protection_used`
stays hidden because the slope is unanswered.

**Scenario C: a hidden field is never required.**

```bash
make scenario ARGS="template '{\"roof_material\":\"metal\",\"slope_degrees\":12}'"
```

Expected: `fall_protection_used` is neither visible nor required. This is the rule that
matters most in the engine. A field that is required but invisible blocks submission with no
way for the inspector to discover which one, and no way to fix it from a roof.

**Scenario D: a steep roof brings a safety question.**

```bash
make scenario ARGS="template '{\"roof_material\":\"tile\",\"slope_degrees\":45}'"
```

Expected: `fall_protection_used` is now visible and required.

**Scenario E: a conditional capture requirement.**

```bash
make scenario ARGS="template '{\"roof_material\":\"asphalt_shingle\",\"slope_degrees\":20}'"
```

Expected: both `elevation_photos` and `damage_closeups` are outstanding. Compare with
`metal`, where only `elevation_photos` applies.

**Scenario F: partial capture progress.**

```bash
make scenario ARGS="template '{\"roof_material\":\"metal\",\"slope_degrees\":20}' '{\"elevation_photos\":3}'"
```

Expected: `elevation_photos needs 1 more`.

**Scenario G: a value outside its declared range.**

```bash
make scenario ARGS="template '{\"roof_material\":\"metal\",\"slope_degrees\":120}'"
```

Expected: `slope_degrees is outside 0.0 to 90.0`.

**Scenario H: a complete inspection.**

```bash
make scenario ARGS="template '{\"roof_material\":\"metal\",\"slope_degrees\":22,\"access_notes\":\"Ladder at the north elevation.\"}' '{\"elevation_photos\":4}'"
```

Expected: `nothing: this inspection can be submitted`.

### 7.3 Storage and thermal scenarios

```bash
make scenario ARGS="storage 10GB"     # ample
make scenario ARGS="storage 1GB"      # warning: eviction of confirmed-synced media begins
make scenario ARGS="storage 400MB"    # blocked, with the shortfall named
```

The blocked case is the one to read. Capture is refused **before** acquisition, and the
message names how many bytes are needed. "Free up 112 MB" is an instruction; "storage full"
is a complaint.

```bash
make scenario ARGS="thermal nominal"
make scenario ARGS="thermal serious"    # inference at reduced resolution
make scenario ARGS="thermal critical"   # inference deferred, capture unaffected
```

Capture never stops for heat. Losing the evidence is worse than losing the analysis: the
analysis can be redone from the media, the site cannot be revisited.

### 7.4 Phase 3 regression, database

Unchanged by Phase 4a, worth confirming after any archive overlay.

```bash
make db-status     # 2 of 2 migration file(s) recorded; tenants=2 users=4 devices=3
make db-verify     # 8 isolation checks
```

If the volume was destroyed:

```bash
make db-reset      # rebuild, migrate, seed
```

Seed identifiers, unchanged from Phase 3:

| Entity | Identifier |
|---|---|
| Tenant A, Northwind Mutual | `11111111-1111-4111-a111-111111111111` |
| Tenant B, Pacific Grid Utilities | `22222222-2222-4222-a222-222222222222` |
| Dana Reyes, inspector, tenant A | `a1111111-1111-4111-a111-111111111111` |
| Priya Shah, reviewer and admin, tenant A | `a2222222-2222-4222-a222-222222222222` |
| Marcus Obi, inspector, tenant B | `b1111111-1111-4111-a111-111111111111` |
| Sam Whitfield, suspended, tenant B | `b2222222-2222-4222-a222-222222222222` |

### 7.5 Durability scenarios

These have no command-line equivalent, because the sequence they assert is an ordering
rather than a value. They run as tests:

```bash
cd ~/aperture
make core-test-filter FILTER="CaptureMediaTests"
```

| Scenario | Assertion |
|---|---|
| Normal capture | Steps are `checkedSpace`, `wrote`, and only then is the caller told |
| Record and operation | Both present, committed together |
| Storage exhausted | Steps are `checkedSpace` only. Nothing written, nothing recorded |
| Storage refusal message | Names the shortfall in bytes |
| Write fails | No record, no queued operation |
| Transaction fails | Steps are `checkedSpace`, `wrote`, `removed`. The orphan is reclaimed |
| Rollback also fails | The original failure is still what surfaces, not the cleanup failure |
| Same bytes twice | Identical content hash, distinct asset identifiers |

---

## Part 8: verify the expected results

```bash
cd ~/aperture
make check              && echo "1/6 static checks"
make core-test-docker   && echo "2/6 swift suites"
make backend-test       && echo "3/6 go suites"
curl -sf localhost:8080/readyz >/dev/null && echo "4/6 service healthy"
make db-verify          && echo "5/6 tenant isolation"
make scenario ARGS="template '{}'" >/dev/null && echo "6/6 scenario tool"
```

| Check | Expected |
|---|---|
| `make check` | boundaries OK, 13 schema assertions, configuration OK |
| `make core-test-docker` | ~145 tests, ~24 suites, 0 failures |
| `make backend-test` | `ok` for `internal/authn` and `internal/tenancy` |
| `/readyz` | `{"status":"ready"}` |
| `make db-verify` | 8 passes, "Tenant isolation verified" |
| `make scenario` | Prints a decision table without erroring |

---

## Part 9: troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| Archive MD5 does not match | Stale download, browser kept an earlier copy | Re-download, re-upload, verify before extracting |
| `make scenario` fails to build | First run compiles the executable target | Normal, allow a minute. Re-run |
| `make scenario` prints a JSON parse error | Shell quoting. Inner quotes need escaping | Use the exact forms in Part 7.2 |
| Scenario shows a field as absent that you passed | Key typo, or a value shape the field does not accept | `make scenario ARGS="fields"` to see the exact keys and kinds |
| `swift: command not found` | VM recycled | `source ~/.bashrc`, or use the container targets |
| `.build` permission denied | An earlier container ran as root | `sudo chown -R $(id -u):$(id -g) ios/Packages/ApertureCore/.build` |
| `make core-test-docker` cannot resolve swift-crypto | No egress from the container | `docker run --rm swift:6.3 curl -sI https://github.com` |
| `port is already allocated` | Another Postgres or service | `docker ps`, stop it, or change the port in `.env` |
| `db-status` shows no tables, no role, no migrations | The volume is gone: VM recycle, `down -v`, or a prune | `make db-migrate && make db-seed`, or `make db-reset` |
| `db-verify` reports `aperture_app does not exist` | Same cause, seen from the other end | Same fix |
| `db-migrate` says a file was edited after it was applied | A migration changed after running | Write a new migration, or `make db-reset` |
| `db-verify` reports tenant A sees 4 users | Connected as a superuser | The script uses `aperture_app`; confirm with `\du` |
| Everything worked yesterday, nothing today | VM recycled: images gone, `$HOME` kept | Part 2, then Part 4 |
| `ios` workflow fails | Expected until Phase 4b | It compiles the app target, which Phase 4a does not touch |

### Full teardown

```bash
cd ~/aperture
make backend-down
docker compose -f infra/docker-compose.yml down -v   # also destroys the database volume
docker system prune -af                              # reclaims the VM disk, not $HOME
```
