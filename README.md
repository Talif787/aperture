# Aperture

Offline-first field inspection platform. Inspectors capture photographic, video, and LiDAR
evidence at a site with no connectivity, on-device models detect and measure defects
immediately, and structured findings converge with the back office when signal returns.

**Status: Phase 1 of 13, repository and build foundation.**

This repository is built in phases, each independently buildable and testable. What exists
is described below; what does not exist yet is named as such.

## The three hard problems

1. **Convergence under partition.** Devices work offline for up to 72 hours while reviewers
   edit the same records server-side. Resolution uses hybrid logical clocks and per-field
   dirty tracking, and numeric measurements are never merged automatically, because
   silently choosing between two damage measurements is a legal exposure.
2. **Durability across termination.** The operating system kills the app; that is normal,
   not exceptional. Every capture is committed to disk before the interface acknowledges
   it, and operations left in flight by a terminated process are re-driven on the next
   launch with their original idempotency keys.
3. **Power and thermal budget.** Sustained camera, ARKit, and Neural Engine load across an
   eight-hour shift is genuinely hard. It is measured per release rather than assumed.

## Repository layout

```
contracts/    Protobuf, OpenAPI, conformance fixtures. Source of truth for every client
ios/          Swift 6.4, SwiftUI, two local packages (see ADR-0001)
backend/      Go service, modular monolith
infra/        Terraform, docker-compose
ml/           Model conversion, evaluation, quantization study
scripts/      Bootstrap, codegen, boundary and schema verification
docs/         Architecture, ADRs, runbooks, guides
```

## What Phase 1 contains

- Repository structure and build configuration for three environments
- Two Swift packages split on Linux buildability, with enforced module boundaries
- A domain layer with no framework dependencies: typed identifiers, UUIDv7, the error model
- A sync layer with the retry schedule and the operation state machine, both tested
- A Go service with structured logging, correlation-id propagation, and graceful shutdown
- CI: boundary enforcement, schema verification, Linux Swift tests, Go tests, SwiftLint,
  and a path-filtered macOS job that compiles the app target
- `scripts/check_module_boundaries.py` and `scripts/verify_queue_schema.py`, both of which
  fail the build when the rule they encode is broken

## What Phase 1 does not contain

Persistence implementation, authentication, capture, on-device inference, the sync engine
itself, and the backend's sync endpoints. Each arrives in its named phase. See the phase
plan in the Phase 0 engineering plan.

## Quick start

**In Google Cloud Shell**, upload `aperture-phase-1.zip`, then:

```bash
cd ~ && unzip -q aperture-phase-1.zip && cd ~/aperture
chmod +x scripts/*.sh scripts/*.py
make check                      # verifies the archive, needs no toolchain
./scripts/cloudshell_setup.sh   # installs Swift for Linux and the GitHub CLI
source ~/.bashrc
make doctor                     # reports what this machine can build
```

Then follow [SETUP.md](SETUP.md), which covers GitHub repository creation, branch
protection, Google Cloud project setup, and keyless CI credentials through Workload
Identity Federation.

**On macOS**, from a clone:

```bash
./scripts/bootstrap.sh
make help
```

Everyday commands:

```bash
make doctor       # what this machine can build, and what is missing
make check        # boundaries, schema, configuration. No toolchain required
make core-test    # domain and sync tests. Runs on Linux
make backend-up   # Postgres and the service in Docker
```

## Build matrix

| Component | Linux | macOS |
|---|---|---|
| `ApertureCore` (domain, sync, contracts) | Yes | Yes |
| `AperturePlatform` (data, security, telemetry, design system, features) | No | Yes |
| App target and simulator | No | Yes |
| Backend | Yes | Yes |

The split is deliberate and is explained in [ADR-0001](docs/adr/0001-two-swift-packages.md).
The framework-free half contains the sync engine and the conflict policy, which is the
code where correctness matters most and where fast tests matter most.

## Decisions worth reading

- [ADR-0001](docs/adr/0001-two-swift-packages.md), two Swift packages split on Linux buildability
- `SyncQueueSchema.swift`, why the queue is SQLite rather than SwiftData, and why
  `before_state` and `inFlight` exist
- `RetryPolicy.swift`, why full jitter rather than equal jitter
- `KeychainAccessPolicy.swift`, why `AfterFirstUnlock` rather than `WhenUnlocked`

## License

Not yet licensed. All rights reserved pending a decision before the repository is made
public.

