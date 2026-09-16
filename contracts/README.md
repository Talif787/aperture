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

## Domain types are not wire types

`Inspection`, `Finding`, `MediaAsset`, `SyncMetadata` and the rest conform to `Codable`,
and that conformance is for local persistence and test round-trips only. It is symmetric:
the same code encodes and decodes, so the key names are private to the device and carry no
contract obligation.

Wire types are generated from this directory and live in `ApertureContracts`. The data
layer maps between the two. A domain type must never be encoded directly onto the wire,
because that would silently make every property name part of the protocol, and renaming a
field for clarity would become a breaking change nobody noticed.

The exception is anything that decodes a server payload directly, such as `APIError`.
Those carry explicit `CodingKeys` matching the documented envelope. Explicit rather than a
decoder-wide snake-case strategy, for a specific reason: every field in an error envelope
is optional, so a key mismatch does not throw. It decodes successfully with nils, and the
failure surfaces far downstream as a missing value nobody can explain.

## Why the conformance corpus exists

The conflict policy is implemented twice, in Swift and in Go, and two implementations of
the same rules eventually disagree. Shared code would prevent that by construction but
requires a shared toolchain and a shared release cadence. The corpus prevents it by
detection instead: both implementations execute the same scenarios and assert the same
outcomes, and a divergence fails the build of whichever side moved.

It is also executable documentation of the protocol, which is what a third client or a
partner integration would need.
