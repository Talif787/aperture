# Local development

## What builds where

This is the first thing to understand, because it shapes every other workflow decision.

| Component | Linux / Cloud Shell | macOS |
|---|---|---|
| `ApertureCore` (domain, sync, contracts, test support) | **Yes** | Yes |
| `AperturePlatform` (data, security, telemetry, design system, features) | No | Yes |
| The app target and the simulator | No | Yes |
| Backend (Go) | **Yes** | Yes |
| Boundary, schema, and configuration checks | **Yes** | Yes |
| Terraform, docs, contracts | **Yes** | Yes |

The Linux column is not a limitation of the tooling. SwiftUI, SwiftData, AVFoundation,
Core ML, and ARKit do not exist on Linux, and Xcode does not run there.

The Linux column is also not small. It contains the sync engine, the conflict policy, the
retry schedule, and the domain model, which is where the correctness risk in this product
actually lives.

## Setup

```bash
git clone https://github.com/<owner>/aperture.git
cd aperture
./scripts/bootstrap.sh
make doctor
```

In Cloud Shell, start from the ZIP rather than a clone, and follow
[SETUP.md](../../SETUP.md), which is the full runbook for that environment.

## Common tasks

```bash
make help            # every target
make check           # boundaries, schema, configuration. No toolchain required
make core-test       # ApertureCore, on Linux or macOS
make backend-test    # Go tests with the race detector
make backend-up      # Postgres and the service in Docker
make ci-local        # what the pull request job runs
```

macOS only:

```bash
make project         # generate Aperture.xcodeproj from ios/project.yml
make ios-build
make ios-test
```

## The Xcode project is generated

`ios/Aperture.xcodeproj` is not committed. It is produced from `ios/project.yml` by
XcodeGen. Two reasons: a project file is the worst merge conflict in iOS development, and a
text specification can be edited and reviewed from an environment where Xcode does not
exist.

After changing `project.yml`, run `make project`.

## Build configurations

Three, defined in `ios/Config/`. Each points at a different backend and uses a different
bundle identifier, so all three can be installed side by side on one device.

| Configuration | Backend | Bundle suffix |
|---|---|---|
| Debug | `http://localhost:8080` | `.debug` |
| Staging | staging API | `.staging` |
| Release | production API | none |

`AppEnvironment.current` reads these values and calls `fatalError` if any are missing. A
misconfigured build should refuse to launch rather than silently point at the wrong
backend, which is a mistake customers discover rather than engineers.

## Before opening a pull request

```bash
make ci-local
```

If a boundary check fails, the message names the file, the rule, and the fix. The rules
are in [ADR-0001](../adr/0001-two-swift-packages.md).
