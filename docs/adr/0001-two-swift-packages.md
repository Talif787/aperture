# ADR-0001: Two Swift packages split on Linux buildability

**Status:** Accepted
**Date:** 2026-09-14
**Supersedes:** the eleven-package layout proposed in the Phase 0 engineering plan, section 0.7.1

## Context

Phase 0 specified eleven local Swift packages, one per module. Phase 1 then introduced a
constraint that was not present when that plan was written: development happens primarily
in Google Cloud Shell, which is Linux.

Cloud Shell cannot build the application. Xcode is macOS-only, and SwiftUI, SwiftData,
AVFoundation, Core ML, and ARKit do not exist on Linux. No toolchain changes that.

What Cloud Shell *can* build is any Swift code that imports no Apple framework. The Phase 0
layering rule already requires exactly that of `ApertureDomain` and `ApertureSync`, and
those two modules happen to contain the hardest and most correctness-critical logic in the
product: conflict resolution, hybrid logical clocks, the retry schedule, and the queue
state machine.

## Decision

Two packages, split on the one boundary that is now load-bearing:

- **`ApertureCore`** contains every framework-free module: `ApertureDomain`,
  `ApertureSync`, `ApertureContracts`, `ApertureTestSupport`. It builds and tests on Linux,
  therefore in Cloud Shell and on an ubuntu CI runner.
- **`AperturePlatform`** contains everything that legitimately depends on an Apple
  framework. It builds on macOS only.

Module boundaries are still enforced per target rather than per package, by
`scripts/check_module_boundaries.py`, which runs on every pull request.

## Alternatives considered

**Keep eleven packages.** Rejected. Eleven manifests is meaningful boilerplate, and the
per-package boundary it buys is already available at target granularity within a package.
It also does not express the boundary that now matters most.

**One package with all targets.** Rejected. `swift build` on Linux would fail on the first
Apple-framework import, so the Linux-buildable surface would exist only by convention.
Splitting the packages makes it a build-level fact.

**Develop entirely on macOS.** Rejected as a Phase 1 assumption rather than on the merits:
a Mac may become available later, at which point nothing here needs to change. The split
remains useful regardless, because it keeps the fast test suite runnable on cheap
infrastructure.

## Consequences

**Good.** The domain and sync suites run in seconds on Linux, in Cloud Shell, and on an
ubuntu CI runner that costs roughly a tenth of a macOS runner. The framework-purity rule
becomes a compile error rather than a code review note. The path to extracting the sync
engine into Kotlin Multiplatform later is shorter, because the code is already proven free
of platform dependencies.

**Bad.** The app target and every UI change require macOS. Until a Mac is available, the
only thing that compiles them is the `ios.yml` workflow on a GitHub-hosted macOS runner,
which makes the inner loop for UI work minutes rather than seconds. That is genuinely
painful and it is an accepted cost of the development environment, not a design benefit.

**Watch for.** Pressure to put "just one" Apple import into `ApertureCore` for
convenience. The boundary checker will reject it, and the correct response is to move the
code to `AperturePlatform` or to express the dependency as a protocol in the domain layer.
