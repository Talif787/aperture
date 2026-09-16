# contracts

The wire contract, and the source of truth for every implementation of it.

This directory sits at the top level of the repository rather than under `backend/` or
`ios/` deliberately: its position expresses that it belongs to neither. A protocol owned
by one side of the wire drifts toward that side.

## Layout

```
proto/       Protobuf schema for the sync channel      (Phase 2)
openapi/     OpenAPI 3.1 for the REST surface          (Phase 2)
conformance/ JSON fixtures every implementation runs   (Phase 5)
analytics/   Versioned analytics event schema          (Phase 8)
tokens/      Design tokens, generated to Swift/Kotlin  (Phase 4)
```

## Rules

Generated code is never hand-edited and never committed. `scripts/generate.sh` produces it,
and CI regenerates and diffs to prove no hand edit survived.

Evolution within a major version is additive only. New optional fields are free. Removing
a field, renaming one, narrowing a type, or changing what a field means requires a new
major version, and the two run concurrently for at least twelve months because field
devices run old builds for months at a time.

Protobuf field numbers are never reused. Removed fields are marked `reserved`.

Clients ignore unknown fields, and an unknown enum value renders as an opaque unknown
rather than failing to decode the entity that contains it. A new defect class added
server-side must not strand an inspection on an old client.

## Why the conformance corpus exists

The conflict policy is implemented twice, in Swift and in Go, and two implementations of
the same rules eventually disagree. Shared code would prevent that by construction but
requires a shared toolchain and a shared release cadence. The corpus prevents it by
detection instead: both implementations execute the same scenarios and assert the same
outcomes, and a divergence fails the build of whichever side moved.

It is also executable documentation of the protocol, which is what a third client or a
partner integration would need.
