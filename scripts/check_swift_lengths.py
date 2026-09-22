#!/usr/bin/env python3
"""Approximate SwiftLint's length rules locally, before a push.

SwiftLint counts function bodies *excluding comments and whitespace*. A raw line count
therefore flags every heavily commented function in this codebase, which is most of them,
and a check that cries wolf is one people stop reading. Measuring the way the rule measures
is what makes it worth running.

Not a substitute for SwiftLint, which cannot run here: this exists to catch the two or
three findings that would otherwise cost a CI round trip.
"""
from __future__ import annotations

import pathlib
import re
import sys

REPO_ROOT = pathlib.Path(__file__).resolve().parent.parent

ROOTS = [
    REPO_ROOT / "ios" / "App",
    REPO_ROOT / "ios" / "Packages",
]

FUNCTION_WARNING = 40
TYPE_BODY_WARNING = 250
FILE_WARNING = 400
LINE_WARNING = 120

# Mirrors the `excluded` list in .swiftlint.yml. A local approximation of a rule that scans
# more than the rule does is not an approximation, it is a different check: SPM materializes
# every dependency's sources under .build, and linting code we did not write buried three
# real findings under twelve hundred imaginary ones.
SKIPPED_DIRECTORIES = {".build", "checkouts", "DerivedData", "Generated"}

FUNCTION_PATTERN = re.compile(
    r'^\s*(?:@\w+\s+)*(?:public |private |internal |fileprivate |static |final |override |mutating )*'
    r'func\s+(\w+)'
)
TYPE_PATTERN = re.compile(
    r'^\s*(?:public |private |internal |final |indirect )*(?:struct|class|enum|actor|extension)\s+(\w+)'
)


def effective_length(lines: list[str], start: int, end: int) -> int:
    """Lines between two indices, ignoring blanks and comment-only lines."""
    count = 0
    in_block_comment = False

    for line in lines[start + 1:end]:
        stripped = line.strip()

        if in_block_comment:
            if "*/" in stripped:
                in_block_comment = False
            continue
        if stripped.startswith("/*"):
            if "*/" not in stripped:
                in_block_comment = True
            continue
        if not stripped or stripped.startswith("//"):
            continue

        count += 1

    return count


def closing_index(lines: list[str], start: int) -> int | None:
    depth = 0
    for index in range(start, len(lines)):
        depth += lines[index].count("{") - lines[index].count("}")
        if depth == 0 and index > start:
            return index
    return None


def main() -> int:
    findings: list[str] = []

    for root in ROOTS:
        if not root.is_dir():
            continue

        for path in sorted(root.rglob("*.swift")):
            relative = path.relative_to(REPO_ROOT)

            if any(part in SKIPPED_DIRECTORIES or part.startswith(".") for part in relative.parts):
                continue
            text = path.read_text(encoding="utf-8")
            lines = text.splitlines()

            if text.count("{") != text.count("}"):
                findings.append(f"{relative}: braces unbalanced")

            if len(lines) > FILE_WARNING:
                findings.append(f"{relative}: file is {len(lines)} lines (limit {FILE_WARNING})")

            for number, line in enumerate(lines, 1):
                if len(line) > LINE_WARNING:
                    findings.append(f"{relative}:{number}: line is {len(line)} characters")

            for index, line in enumerate(lines):
                # A declaration that does not open a brace on its own line is a protocol
                # requirement or a multi-line signature, neither of which has a body here.
                if not line.rstrip().endswith("{"):
                    continue

                match = FUNCTION_PATTERN.match(line)
                if match:
                    end = closing_index(lines, index)
                    if end is None:
                        continue
                    length = effective_length(lines, index, end)
                    if length > FUNCTION_WARNING:
                        findings.append(
                            f"{relative}:{index + 1}: func {match.group(1)} body is "
                            f"{length} lines excluding comments (limit {FUNCTION_WARNING})"
                        )
                    continue

                match = TYPE_PATTERN.match(line)
                if match:
                    end = closing_index(lines, index)
                    if end is None:
                        continue
                    length = effective_length(lines, index, end)
                    if length > TYPE_BODY_WARNING:
                        findings.append(
                            f"{relative}:{index + 1}: type {match.group(1)} body is "
                            f"{length} lines excluding comments (limit {TYPE_BODY_WARNING})"
                        )

    if findings:
        print("Swift length findings:")
        for finding in findings:
            print(f"  {finding}")
        print(f"\n{len(findings)} finding(s). SwiftLint runs with --strict, so these fail CI.")
        return 1

    print("Swift lengths OK: functions, type bodies, files, and line widths.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
