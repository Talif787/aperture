## What and why

<!-- What changes, and what problem it solves. Link the issue. -->

## Architectural impact

- [ ] No new module boundary crossed
- [ ] No new third-party runtime dependency (or: an ADR is included)
- [ ] `ApertureCore` still imports no Apple framework
- [ ] No `@unchecked Sendable` added
- [ ] Contract unchanged (or: both client and server updated, conformance fixtures added)

## Correctness

- [ ] New logic has unit tests in the domain or sync layer
- [ ] Failure paths are covered, not only the happy path
- [ ] If offline behavior changed, the offline test matrix was updated
- [ ] If persistence changed, a migration and a migration test are included

## Security and privacy

- [ ] No secret, token, or key material added to the repository
- [ ] No user content added to a log, event, or crash payload
- [ ] Authorization enforced server-side, not only in the client

## Verification

<!-- Which of these you actually ran, not which you assume pass. -->

```
make check
make core-test
make backend-test
```

## Screenshots or output

<!-- For UI changes: light, dark, and Dynamic Type at AX5. -->
