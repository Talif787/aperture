#!/usr/bin/env python3
"""List every test suite with the identifier `swift test --filter` actually matches.

`--filter` takes a regular expression matched against the Swift *type* name, not the
display string in `@Suite("...")`. The two routinely differ, and a filter that matches
nothing exits successfully with "No matching test cases were run", which reads like a
passing run at a glance.
"""
from __future__ import annotations

import pathlib
import re
import sys

REPO_ROOT = pathlib.Path(__file__).resolve().parent.parent
TEST_ROOTS = [
    REPO_ROOT / "ios" / "Packages" / "ApertureCore" / "Tests",
    REPO_ROOT / "ios" / "Packages" / "AperturePlatform" / "Tests",
]

# Build products and dependency checkouts are not our code. SPM materializes every
# dependency under .build, and a checker that walks them reports findings nobody can act on.
SKIPPED_PARTS = {".build", "checkouts", "DerivedData", ".git"}


def is_ours(path) -> bool:
    return not any(part in SKIPPED_PARTS or part.startswith(".") for part in path.parts)

SUITE_PATTERN = re.compile(r'@Suite\(\s*\n?\s*"([^"]+)"[^)]*\)\s*\n\s*struct\s+(\w+)')


def main() -> int:
    rows: list[tuple[str, str, str]] = []

    for root in TEST_ROOTS:
        if not root.is_dir():
            continue
        for path in sorted(p for p in root.rglob("*.swift") if is_ours(p)):
            text = path.read_text(encoding="utf-8")
            for match in SUITE_PATTERN.finditer(text):
                rows.append((match.group(1), match.group(2), path.name))

    if not rows:
        print("No suites found.")
        return 1

    needle = sys.argv[1].lower() if len(sys.argv) > 1 else None
    if needle:
        rows = [row for row in rows if needle in row[0].lower() or needle in row[1].lower()]
        if not rows:
            print(f"No suite matches '{sys.argv[1]}'.")
            return 1

    width = max(len(display) for display, _, _ in rows)
    print(f"{'suite'.ljust(width)}  filter with")
    print(f"{'-' * width}  {'-' * 28}")
    for display, typename, _ in sorted(rows):
        print(f"{display.ljust(width)}  {typename}")

    print(f"\n{len(rows)} suite(s). Run one with:")
    print(f'  make core-test-filter FILTER="{sorted(rows)[0][1]}"')
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
