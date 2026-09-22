#!/usr/bin/env python3
"""Approximate SwiftLint's structural rules locally, before a push.

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

# Rules beyond length that CI kept finding and this script kept missing. Every one of them
# cost a round trip, which is the argument for approximating them here even though the
# approximation is cruder than the real rule.
TUPLE_RETURN_PATTERN = re.compile(r'->\s*\(([^)]*)\)\s*\{?\s*$')
BLANKET_DISABLE_PATTERN = re.compile(r'//\s*swiftlint:disable\s+(?!next|this|previous)(\w+)')
DOC_COMMENT_PATTERN = re.compile(r'^\s*///')

# Binding a value only to discard it. `!= nil` says what is actually being tested, and the
# binding form reads as though the value is used.
UNUSED_BINDING_PATTERN = re.compile(r'\b(?:if|while|guard)\s+let\s+_\s*=')

# A closure parameter named but never referenced should be `_`.
FORCE_TRY_PATTERN = re.compile(r'\btry!\s')

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
    if not self_test():
        print("Pattern self-test failed. The checks below would report clean regardless.")
        return 2

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

            if text and not text.endswith("\n"):
                findings.append(f"{relative}: no trailing newline")
            elif text.endswith("\n\n"):
                findings.append(f"{relative}: more than one trailing newline")

            blank_run = 0
            for number, line in enumerate(lines, 1):
                if len(line) > LINE_WARNING:
                    findings.append(f"{relative}:{number}: line is {len(line)} characters")

                if not line.strip():
                    blank_run += 1
                    if blank_run == 2:
                        findings.append(
                            f"{relative}:{number}: more than one consecutive blank line"
                        )
                else:
                    blank_run = 0

                if UNUSED_BINDING_PATTERN.search(line):
                    findings.append(
                        f"{relative}:{number}: binds a value only to discard it; use != nil"
                    )

                if FORCE_TRY_PATTERN.search(line) and not line.strip().startswith("//"):
                    findings.append(f"{relative}:{number}: force try")

                disable = BLANKET_DISABLE_PATTERN.search(line)
                if disable:
                    findings.append(
                        f"{relative}:{number}: blanket disable of {disable.group(1)}; "
                        f"use :next, :this, :previous, or the configuration file"
                    )

                # A tuple of three or more members should be a named type. Positional
                # access reads as .0 and .2, and a swap between two same-typed members is
                # invisible at the call site.
                tuple_match = TUPLE_RETURN_PATTERN.search(line)
                if tuple_match and tuple_match.group(1).count(",") >= 2:
                    findings.append(
                        f"{relative}:{number}: returns a tuple of "
                        f"{tuple_match.group(1).count(',') + 1} members"
                    )

            # A doc comment must attach to a declaration. One separated from the next line
            # by a blank line documents nothing and reads as if it does.
            for number, line in enumerate(lines):
                if not DOC_COMMENT_PATTERN.match(line):
                    continue
                following = lines[number + 1] if number + 1 < len(lines) else ""
                if DOC_COMMENT_PATTERN.match(following) or following.strip():
                    continue
                findings.append(f"{relative}:{number + 1}: doc comment attached to nothing")

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

    print("Swift structure OK: lengths, widths, tuples, doc comments, whitespace.")
    return 0




def self_test() -> bool:
    """Confirm each pattern still matches what it is meant to match.

    Added after an edit silently turned every regex into one matching a literal backslash.
    The script kept reporting clean, which is the worst way for a checker to fail: it looks
    like evidence and is the absence of it. Cheap insurance against the same class.
    """
    cases = [
        (TUPLE_RETURN_PATTERN, "    func f() -> (a: Int, b: Int, c: Int) {"),
        (BLANKET_DISABLE_PATTERN, "// swiftlint:disable no_print"),
        (DOC_COMMENT_PATTERN, "/// A doc comment"),
        (UNUSED_BINDING_PATTERN, "while let _ = iterator.next() {}"),
        (FORCE_TRY_PATTERN, "let value = try! thing()"),
        (FUNCTION_PATTERN, "    public func doThing() {"),
        (TYPE_PATTERN, "public struct Thing {"),
    ]

    for pattern, sample in cases:
        if not pattern.search(sample):
            print(f"self-test failed: {pattern.pattern!r} no longer matches {sample!r}")
            return False

    return True


if __name__ == "__main__":
    raise SystemExit(main())
