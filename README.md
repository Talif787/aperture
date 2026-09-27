# Aperture

Offline-first field inspection platform. Inspectors capture photographic and LiDAR evidence
at a site with no connectivity, and structured findings converge with the back office when
signal returns.

**The backend is complete and verifiable. The iOS client is partial and blocked on
hardware.** What exists is described below; what does not is named as such, because a
repository that overstates itself is worse than one that is small.

---

## Try it in five minutes

```bash
git clone https://github.com/Talif787/aperture && cd aperture
make backend-deps                 # resolves the one third-party dependency
make backend-up                   # Postgres in Docker
make db-migrate && make db-seed
make api-up-postgres
make api-scenarios                # 24 assertions against the running service
make db-verify                    # 22 tenant isolation checks, in the database
```

Every claim below is checked by something in that list. `docs/guides/` has a runbook per
phase with the failure modes each one actually hit.

---

## The three hard problems

**Convergence under partition.** Devices work offline for up to 72 hours while reviewers
edit the same records server-side. Resolution uses hybrid logical clocks and per-field
dirty tracking. A version mismatch alone is not a conflict: two people editing different
fields of one record is concurrency, and prompting for it would happen several times a
shift for nothing. Numeric measurements are never merged automatically, because silently
choosing between two damage measurements is a legal exposure.

**Durability across termination.** The operating system kills the app; that is normal, not
exceptional. Every capture is committed to disk before the interface acknowledges it, and
operations left in flight by a terminated process are re-driven on the next launch with
their original idempotency keys. Exactly-once effect holds across a process death on both
sides, which `make api-scenarios` demonstrates by restarting the service mid-run.

**Tenant isolation that survives a mistake.** Every table has row-level security, and the
service connects as a `NOSUPERUSER NOBYPASSRLS` role. A query that forgets its `WHERE`
clause returns nothing rather than another carrier's inspections. The test harness asserts
the role cannot bypass row security *before* connecting as it, because a superuser
connection would pass every isolation test against policies never consulted.

---

## What is real

| Area | State | Verified by |
|---|---|---|
| Sync protocol: per-field conflicts, tenant-scoped idempotency, cursor paging | Complete | `make api-scenarios`, 24 assertions |
| PostgreSQL persistence with row-level security on every table | Complete | `make db-verify` (22), `make backend-test-integration` |
| Bearer token verification, JWKS caching, key rotation | Complete | `make backend-test`, 8 fuzz targets |
| Prometheus metrics with enforced label cardinality | Complete | `make metrics-scenarios`, 17 assertions |
| Per-tenant rate limiting with bounded memory | Complete | `make ratelimit-scenarios`, 14 assertions |
| Domain, sync engine, and convergence proofs (Swift, Linux-buildable) | Complete | `make core-test-docker`, ~200 tests |
| Capture pipeline, SwiftUI views | **Not built** | Needs macOS and a device |
| Push notifications, background refresh | **Not built** | Needs APNs credentials |
| Terraform, Cloud SQL, deployment | **Not built** | Deferred until it would cost money |

131 Go tests, 12 benchmarks, 8 fuzz targets, roughly 200 Swift tests across 76 files.

---

## What `make check` enforces

This is the part that is invisible from a file listing, and it is where most of the
engineering judgement lives. It runs in under two seconds and needs no toolchain.

**Architecture, mechanically enforced rather than documented:**

- `ApertureCore` imports no Apple framework, so the domain stays buildable and testable on
  Linux. The fastest tests cover the hardest logic.
- Feature modules cannot import each other, and the module graph is acyclic.
- **Only `internal/store` may import a database driver.** Tenant scoping is applied when a
  session opens, so a second package able to open one would make that scoping a convention
  rather than a property. Verified by planting a rogue package and watching the check fail.

**Correctness, checked without a compiler:**

- The sync queue DDL is executed against SQLite and its behaviour asserted, 13 checks,
  including that the dispatch query uses an index rather than scanning.
- The Go module floor cannot creep upward, because a dependency raising it forces a
  toolchain download on any older machine.
- `go.mod` must agree with the source.

**Formatting and lint rules that would otherwise cost a CI round trip**, each added after
one did: gofmt alignment for declaration groups and composite literals (which follow
different rules), trailing comment alignment measured in runes rather than bytes, context
as the first parameter, `errors.Is` rather than `==`, method names the standard library
reserves, and selectors through embedded fields.

Every one of those was added after a real failure, and each was verified by reintroducing
the defect and watching the check catch it. A check nobody has watched fail is a check
nobody knows works.

---

## Repository layout

```
contracts/    Protobuf, OpenAPI, conformance fixtures. Source of truth for every client
ios/          Swift 6, two local packages split on Linux buildability (ADR-0001)
backend/      Go service, modular monolith, one third-party dependency
infra/        docker-compose, database grants, seed data
scripts/      Verification, scenarios, database tooling. 14 of them, all executable
docs/         ADRs and a runbook per phase
```

**`backend/` has exactly one third-party dependency**, a PostgreSQL driver, pinned. The
metrics registry, rate limiter, and JWT verifier are written against the standard library.
That was not asceticism: it means the project builds on a machine that cannot reach the Go
module proxy, which Cloud Shell frequently cannot.

---

## Testing

```bash
make backend-test              # unit, race detector
make backend-test-integration  # with PostgreSQL, so the store tests run rather than skip
make fuzz                      # 8 targets over the code that parses untrusted input
make coverage                  # a ratchet, not a target
make bench                     # 12 benchmarks on the hot paths
make core-test-docker          # Swift, on Linux, in a container
```

**Coverage is a ratchet.** `scripts/coverage-baseline.json` records what the suite actually
covers and the gate refuses a decrease; four minimums guard the packages where thin tests
are a security problem. The first version of this had eight percentages chosen by judgement
and four failed on their first real run, which is the argument for measuring rather than
declaring.

**Fuzzing is weighted toward the verifier**, the only code an unauthenticated caller
reaches, where a panic is a denial of service for every tenant rather than a bug report.
Writing those tests found a real defect: decoding an empty base64 string succeeds and
yields zero bytes, so a JWKS entry with an empty modulus produced an RSA key with modulus
zero and no error at all.

---

## Things that went wrong, and what changed

Kept because the failures are more informative than the successes.

- A change log query returned every tenant's activity to every caller. The unit test named
  `TestTenantsCannotSeeEachOther` had fetched the result and discarded it with `_ = pulled`.
  A test whose name claims a property its body does not check is worse than no test.
- A development tool used a fixed key identifier, so regenerating the key looked like a
  cache hit and every token it signed failed for an hour. Key identifiers are now RFC 7638
  thumbprints, which is what real providers do and for exactly this reason.
- Isolation assertions counted rows. Counting assumes you know everything else in the
  table, and you stop knowing that the moment anything else writes to it. They now assert
  on identity.
- A fuzz target guarded itself with `recover` and a guess about which panics were the
  harness's fault, which would have silently dismissed real findings.

---

## Development

Built and verified entirely in Google Cloud Shell, which shaped several decisions: the
2 GB Swift container beats the 5 GB `$HOME` quota by living on the ephemeral disk, and the
Go toolchain is pinned low so the project builds without downloading a compiler.

```bash
make help                      # every target, with a description
```

`docs/guides/` has a runbook per phase: environment verification, exact commands, dummy
values for every scenario, and a troubleshooting table of the failures that actually
occurred rather than the ones that might.
