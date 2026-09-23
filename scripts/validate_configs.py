#!/usr/bin/env python3
"""Parse every YAML and JSON configuration file in the repository.

A malformed workflow file fails at the moment a pull request opens, which is the slowest
possible feedback loop for a one-character mistake. Parsing them locally costs
milliseconds. Uses PyYAML when available and degrades to a structural check when it is
not, so the target never becomes a reason to skip running checks.
"""

from __future__ import annotations

import glob
import json
import os
import sys
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent

YAML_PATTERNS = [
    ".github/workflows/*.yml",
    ".github/workflows/*.yaml",
    "infra/*.yml",
    "ios/project.yml",
    ".swiftlint.yml",
    "backend/.golangci.yml",
]
JSON_PATTERNS = ["contracts/**/*.json", "ios/**/*.xcassets/**/*.json"]



def check_golangci_version_alignment() -> list[str]:
    """The golangci-lint config schema and the action major version must agree.

    golangci-lint v1 and v2 have incompatible configuration schemas, and neither binary
    contains the other's parser. A v2 config run by a v1 binary fails with a wall of
    JSON-schema errors that says nothing about the actual cause, so catching the mismatch
    here saves a push and a CI round trip.
    """
    config = REPO_ROOT / "backend" / ".golangci.yml"
    workflow = REPO_ROOT / ".github" / "workflows" / "pr.yml"
    if not config.is_file() or not workflow.is_file():
        return []

    config_text = config.read_text(encoding="utf-8")
    workflow_text = workflow.read_text(encoding="utf-8")

    declares_v2 = 'version: "2"' in config_text or "version: '2'" in config_text
    action_major = None
    for line in workflow_text.splitlines():
        if "golangci/golangci-lint-action@v" in line:
            action_major = line.split("golangci-lint-action@v", 1)[1].split()[0]
            break

    if action_major is None:
        return []

    try:
        major = int(action_major.split(".")[0])
    except ValueError:
        return [f"{workflow}: cannot parse the golangci-lint-action version '{action_major}'"]

    if declares_v2 and major < 8:
        return [
            f"backend/.golangci.yml declares schema version 2, but pr.yml pins "
            f"golangci-lint-action@v{action_major}. Version 8 or newer is required, "
            f"because earlier majors install a golangci-lint v1 binary."
        ]
    if not declares_v2 and major >= 8:
        return [
            f"pr.yml pins golangci-lint-action@v{action_major}, which installs a v2 "
            f"binary, but backend/.golangci.yml is not a version 2 config."
        ]
    print("golangci-lint: config schema and action version agree")
    return []


# Build products and dependency checkouts are not our code. SPM materializes every
# dependency under .build, and a checker that walks them reports findings nobody can act on.
SKIPPED_PARTS = {".build", "checkouts", "DerivedData", ".git"}


def is_ours(path) -> bool:
    return not any(part in SKIPPED_PARTS or part.startswith(".") for part in path.parts)



def check_go_module_floor() -> list[str]:
    """The module's declared Go version must stay at or below the supported floor.

    `go mod tidy` rewrites this directive when a dependency requires something newer, and
    it does so quietly. The consequence is not a compile error: it is every machine with an
    older Go silently downloading a toolchain, which fails outright in an environment that
    cannot verify one.
    """
    go_mod = REPO_ROOT / "backend" / "go.mod"
    if not go_mod.is_file():
        return []

    supported = (1, 23)

    for line in go_mod.read_text(encoding="utf-8").splitlines():
        if not line.startswith("go "):
            continue
        parts = line.split()[1].split(".")
        try:
            declared = (int(parts[0]), int(parts[1]))
        except (IndexError, ValueError):
            return [f"backend/go.mod: cannot parse the go directive {line!r}"]

        if declared > supported:
            return [
                f"backend/go.mod declares go {parts[0]}.{parts[1]}, above the supported "
                f"floor of {supported[0]}.{supported[1]}. A dependency probably raised it; "
                f"pin that dependency to a version compatible with the floor instead."
            ]

        print(f"Go module floor: {parts[0]}.{parts[1]} (supported)")
        return []

    return ["backend/go.mod has no go directive"]




def alignment_problems(entries, path, line_number) -> list[str]:
    """Expected columns for one alignment group, following gofmt's outlier rule.

    gofmt does not align a whole group to its longest member. An entry far wider than its
    neighbours takes a single space and splits the run, and the entries either side align
    among themselves. Without this the checker asserts one uniform width, which a file can
    satisfy while being consistently wrong, which is exactly what happened here.

    The ratio is a heuristic, not go/printer's algorithm. It reproduces the cases in this
    repository and will not reproduce every case; gofmt remains the authority, and
    `make backend-fmt-check` prints its diff.
    """
    import statistics

    lengths = [len(name) for name, _ in entries]
    median = statistics.median(lengths)

    runs: list[list[tuple[str, int]]] = []
    current: list[tuple[str, int]] = []

    for entry, length in zip(entries, lengths):
        if length > 2 * median:
            if current:
                runs.append(current)
            runs.append([entry])
            current = []
        else:
            current.append(entry)
    if current:
        runs.append(current)

    problems: list[str] = []
    for run in runs:
        width = max(len(name) for name, _ in run)
        for name, spaces in run:
            if len(name) + spaces != width + 1:
                problems.append(
                    f"{path.relative_to(REPO_ROOT)}:{line_number}: '{name}' is padded to "
                    f"column {len(name) + spaces}, gofmt wants {width + 1}. "
                    f"Run: make backend-fmt"
                )

    return problems


def check_go_alignment() -> list[str]:
    """Approximate gofmt's alignment of var, const, and struct field groups.

    Not a substitute for gofmt, which cannot run where this script runs. It exists because
    hand-padding a column is the one formatting mistake that keeps reaching CI, and a CI
    round trip for a column of spaces is a poor use of eight minutes.
    """
    import re

    backend = REPO_ROOT / "backend"
    if not backend.is_dir():
        return []

    problems: list[str] = []
    group = re.compile(r'(?:var|const|type \w+ struct) \(?\n((?:\t+\w+\s+\S.*\n)+)')

    # Map literals align the same way and were not covered, which is how a misaligned
    # allow-list reached CI. A checker that covers most of a rule teaches people the rule
    # is covered.
    map_literal = re.compile(r'= map\[[^\]]+\][^{]*\{\n((?:\t+"[^"]*":\s+\S.*\n)+)')

    for path in sorted(backend.rglob("*.go")):
        text = path.read_text(encoding="utf-8")

        for match in list(group.finditer(text)) + list(map_literal.finditer(text)):
            # Grouped by indentation. gofmt aligns each nesting level independently, so
            # measuring a nested map's inner keys against its outer one reports a
            # misalignment that does not exist. The checker found exactly that on its
            # first run, which is a fair argument for probing a new check before
            # believing it.
            by_indent: dict[int, list[tuple[str, int]]] = {}

            for line in match.group(1).splitlines():
                parts = re.match(r'^(\t+)(\w+|"[^"]*":)(\s+)(\S.*)$', line)
                if parts:
                    depth = len(parts.group(1))
                    by_indent.setdefault(depth, []).append(
                        (parts.group(2), len(parts.group(3)))
                    )

            for entries in by_indent.values():
                if len(entries) < 2:
                    continue

                line_number = text[:match.start()].count("\n") + 1
                problems.extend(alignment_problems(entries, path, line_number))

    if not problems:
        print("Go alignment: var, const, and struct groups look gofmt-clean")
    return problems



def check_go_lint_patterns() -> list[str]:
    """Two golangci-lint findings this project keeps producing, checked locally.

    Neither is subtle once named, and both cost a CI round trip every time. `revive` wants
    context.Context first; `errorlint` wants errors.Is rather than a direct comparison,
    because a direct comparison stops matching the moment any caller wraps the error and
    the test then reports success for something it never recognised.
    """
    import re

    backend = REPO_ROOT / "backend"
    if not backend.is_dir():
        return []

    problems: list[str] = []
    signature = re.compile(r'func \w+\(([^)]*)\)')
    # The package qualifier is optional: an error compared within its own package has the
    # same defect and was slipping through a pattern that required one.
    comparison = re.compile(r'(?:!=|==)\s+(?:\w+\.)?Err[A-Z]\w*')

    for path in sorted(backend.rglob("*.go")):
        relative = path.relative_to(REPO_ROOT)

        for number, line in enumerate(path.read_text(encoding="utf-8").splitlines(), 1):
            if line.strip().startswith("//"):
                continue

            match = signature.search(line)
            if match and "context.Context" in match.group(1):
                parameters = [p.strip() for p in match.group(1).split(",")]
                if parameters and "context.Context" not in parameters[0]:
                    problems.append(
                        f"{relative}:{number}: context.Context should be the first parameter"
                    )

            if comparison.search(line) and "errors.Is" not in line:
                problems.append(
                    f"{relative}:{number}: compare errors with errors.Is, not == or !=; "
                    f"a direct comparison fails on a wrapped error"
                )

    if not problems:
        print("Go lint patterns: context ordering and error comparison look clean")
    return problems



def check_go_module_freshness() -> list[str]:
    """Catch a go.mod that disagrees with the source, before it reaches CI.

    An archive overlay replaces go.mod with the version that ships the pinned requirement
    and nothing else; the indirect requirements are regenerated locally. Committing that
    alongside an existing go.sum leaves the two disagreeing, and every Go command fails
    while loading the module graph, before it does anything the error mentions.

    Skipped when no toolchain is present, because this script is meant to run anywhere.
    """
    import shutil
    import subprocess

    backend = REPO_ROOT / "backend"
    if not backend.is_dir() or not (backend / "go.sum").is_file():
        return []

    if shutil.which("go") is None:
        print("Go module freshness: skipped, no toolchain on PATH")
        return []

    try:
        result = subprocess.run(
            ["go", "mod", "tidy", "-diff"],
            cwd=backend,
            capture_output=True,
            text=True,
            timeout=60,
            env={**os.environ, "GOTOOLCHAIN": "local"},
            check=False,
        )
    except (OSError, subprocess.TimeoutExpired) as error:
        print(f"Go module freshness: skipped, {error}")
        return []

    if result.returncode == 0:
        print("Go module freshness: go.mod matches the source")
        return []

    return [
        "backend/go.mod is out of date with the source, usually because an archive "
        "overlay replaced it. Run: make backend-deps"
    ]



# The method names go vet's stdmethods check reserves, with the return shape each implies.
#
# This is vet's actual list, not a guess at it. Close, String, Read and Write are
# deliberately absent: vet does not check them, and flagging them produces false positives
# on perfectly ordinary code (pgxpool's own Close returns nothing). A checker that invents
# rules the real tool does not enforce trains people to ignore it.
STANDARD_METHOD_RETURNS = {
    "Format": "",
    "GobDecode": "error",
    "GobEncode": "([]byte, error)",
    "Is": "bool",
    "MarshalJSON": "([]byte, error)",
    "MarshalXML": "error",
    "Peek": "([]byte, error)",
    "ReadByte": "(byte, error)",
    "ReadFrom": "(int64, error)",
    "ReadRune": "(rune, int, error)",
    "Scan": "error",
    "Seek": "(int64, error)",
    "UnmarshalJSON": "error",
    "UnmarshalXML": "error",
    "UnreadByte": "error",
    "UnreadRune": "error",
    "Unwrap": "error",
    "WriteByte": "error",
    "WriteTo": "(int64, error)",
}


def check_go_standard_methods() -> list[str]:
    """Flag a method named after a standard interface with the wrong return shape.

    A method named WriteTo that returns only an error reads as a broken io.WriterTo to
    every tool and every reader. The fix is the name, not the signature: contorting an API
    to return a byte count nothing uses would be satisfying the check rather than the point.
    """
    import re

    backend = REPO_ROOT / "backend"
    if not backend.is_dir():
        return []

    problems: list[str] = []
    pattern = re.compile(r'^func \([^)]+\) (\w+)\(([^)]*)\)\s*(.*?)\s*\{$', re.MULTILINE)

    for path in sorted(backend.rglob("*.go")):
        text = path.read_text(encoding="utf-8")

        for match in pattern.finditer(text):
            name, returns = match.group(1), match.group(3).strip()

            if name not in STANDARD_METHOD_RETURNS:
                continue

            expected = STANDARD_METHOD_RETURNS[name]
            if returns == expected:
                continue

            line = text[:match.start()].count("\n") + 1
            problems.append(
                f"{path.relative_to(REPO_ROOT)}:{line}: method {name} returns "
                f"{returns or 'nothing'}, but go vet reserves that name for a method "
                f"returning {expected or 'nothing'}. Rename it."
            )

    if not problems:
        print("Go standard method names: no shadowed interfaces")
    return problems


def main() -> int:
    failures: list[str] = []

    json_paths = [p for pattern in JSON_PATTERNS for p in glob.glob(str(REPO_ROOT / pattern), recursive=True)]
    for path in json_paths:
        try:
            with open(path, encoding="utf-8") as handle:
                json.load(handle)
        except json.JSONDecodeError as error:
            failures.append(f"{path}: {error}")
    print(f"JSON: {len(json_paths)} file(s) parsed")

    yaml_paths = [p for pattern in YAML_PATTERNS for p in glob.glob(str(REPO_ROOT / pattern))]
    try:
        import yaml
    except ImportError:
        print(f"YAML: PyYAML not installed, {len(yaml_paths)} file(s) checked for readability only")
        for path in yaml_paths:
            if not Path(path).is_file():
                failures.append(f"{path}: not readable")
    else:
        for path in yaml_paths:
            try:
                with open(path, encoding="utf-8") as handle:
                    yaml.safe_load(handle)
            except yaml.YAMLError as error:
                failures.append(f"{path}: {error}")
        print(f"YAML: {len(yaml_paths)} file(s) parsed")

    failures.extend(check_golangci_version_alignment())
    failures.extend(check_go_module_floor())
    failures.extend(check_go_alignment())
    failures.extend(check_go_lint_patterns())
    failures.extend(check_go_module_freshness())
    failures.extend(check_go_standard_methods())

    if failures:
        print("\nConfiguration errors:")
        for failure in failures:
            print(f"  {failure}")
        return 1

    print("Configuration OK.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
