#!/usr/bin/env python3
"""Enforce a coverage floor per package, computed from the profile directly.

Statement coverage, not the mean of per-function percentages. `go tool cover -func` reports
one number per function, and averaging those weights a one-line accessor the same as a
fifty-line handler: a package can show 80% while most of its statements are untested. The
profile records a statement count per block, so the real figure is available and is what
gets measured here.

A single repository-wide percentage would be the wrong shape for a different reason. It
lets thorough tests on trivial code pay for thin tests on the code deciding whether one
tenant can read another's data, and the average looks respectable either way. The floors
below are therefore uneven, set by what each package is for.
"""
from __future__ import annotations

import json
import re
import sys
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent
PROFILE = REPO_ROOT / "backend" / "coverage.out"

# Two mechanisms, because they answer different questions.
#
# MINIMUMS are a judgement about what a package deserves given what it decides. They are
# few, high, and only on code where thin tests are a security problem rather than a tidiness
# one.
#
# The baseline is a measurement. `make coverage-baseline` records what the suite actually
# covers, and the gate then refuses a decrease. That is a ratchet: coverage can only go up,
# and nobody has to invent a number.
#
# The first version of this file had eight invented floors and four of them failed on the
# first real run, which is the argument for the split. A floor set by judgement is a
# statement of intent; treating it as a gate just teaches people to lower it.
MINIMUMS = {
    # Decides who the caller is, from input an unauthenticated party controls.
    "internal/authn": 70,
    # Decides what a caller may see and whether an edit overwrites someone else's work.
    "internal/syncapi": 70,
    # Tenant scope resolution. Small, and everything downstream trusts it.
    "internal/tenancy": 80,
    # Redaction. Fails silently when it fails at all.
    "internal/obs": 80,
}

BASELINE = REPO_ROOT / "scripts" / "coverage-baseline.json"

# A decrease smaller than this is noise: a refactor that deletes covered lines moves the
# percentage without changing what is tested. Larger than this is a question worth asking.
TOLERANCE = 2.0

# `path/file.go:startLine.startCol,endLine.endCol statements count`
BLOCK = re.compile(r'^(\S+):\d+\.\d+,\d+\.\d+ (\d+) (\d+)$')


def statement_coverage() -> dict[str, tuple[int, int]]:
    """Covered and total statements per package."""
    totals: dict[str, list[int]] = {}

    for line in PROFILE.read_text(encoding="utf-8").splitlines():
        match = BLOCK.match(line.strip())
        if not match:
            continue

        path, statements, count = match.group(1), int(match.group(2)), int(match.group(3))

        package = re.search(r'(internal/\w+)/', path)
        if not package:
            continue

        entry = totals.setdefault(package.group(1), [0, 0])
        entry[1] += statements
        if count > 0:
            entry[0] += statements

    return {package: (covered, total) for package, (covered, total) in totals.items()}


def main() -> int:
    report_only = "--report" in sys.argv
    write_baseline = "--write-baseline" in sys.argv

    if not PROFILE.is_file():
        print("no coverage profile; run: make coverage", file=sys.stderr)
        return 2

    measured = statement_coverage()

    if write_baseline:
        BASELINE.write_text(
            json.dumps(
                {package: round(100.0 * c / t, 1) for package, (c, t) in sorted(measured.items()) if t},
                indent=2,
            )
            + "\n",
            encoding="utf-8",
        )
        print(f"wrote {BASELINE.relative_to(REPO_ROOT)} from this run:")
        for package, (covered, total) in sorted(measured.items()):
            if total:
                print(f"  {package:<22} {100.0 * covered / total:5.1f}%  ({covered}/{total})")
        print("\nCommit it. The gate now refuses a decrease from these numbers.")
        return 0

    baseline = {}
    if BASELINE.is_file():
        baseline = json.loads(BASELINE.read_text(encoding="utf-8"))

    failures: list[str] = []

    for package in sorted(set(measured) | set(MINIMUMS) | set(baseline)):
        if package not in measured:
            print(f"  ---- {package:<22} no data")
            continue

        covered, total = measured[package]
        percent = 100.0 * covered / total if total else 0.0

        notes = []
        failed = False

        minimum = MINIMUMS.get(package)
        if minimum is not None:
            notes.append(f"min {minimum}%")
            if percent < minimum:
                failed = True
                failures.append(
                    f"{package} is at {percent:.1f}%, below its minimum of {minimum}%"
                )

        previous = baseline.get(package)
        if previous is not None:
            notes.append(f"was {previous}%")
            if percent < previous - TOLERANCE:
                failed = True
                failures.append(
                    f"{package} fell from {previous}% to {percent:.1f}%"
                )

        if not notes:
            notes.append("no minimum, no baseline")

        print(f"  {'LOW ' if failed else 'ok  '} {package:<22} {percent:5.1f}%  "
              f"({covered}/{total} statements, {', '.join(notes)})")

    if report_only:
        print("\nReport only; nothing enforced.")
        return 0

    if not baseline:
        print("\nNo baseline recorded. Run: make coverage-baseline")

    if failures:
        print("\nCoverage problems:")
        for failure in failures:
            print(f"  {failure}")
        return 1

    print("\nCoverage acceptable.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
