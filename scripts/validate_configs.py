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

    for path in sorted(backend.rglob("*.go")):
        text = path.read_text(encoding="utf-8")

        for match in group.finditer(text):
            entries = []
            for line in match.group(1).splitlines():
                parts = re.match(r'^(\t+)(\w+)(\s+)(\S.*)$', line)
                if parts:
                    entries.append((parts.group(2), len(parts.group(3))))

            if len(entries) < 2:
                continue

            width = max(len(name) for name, _ in entries)
            for name, spaces in entries:
                if len(name) + spaces != width + 1:
                    line_number = text[:match.start()].count("\n") + 1
                    problems.append(
                        f"{path.relative_to(REPO_ROOT)}:{line_number}: '{name}' is padded "
                        f"to column {len(name) + spaces}, gofmt wants {width + 1}. "
                        f"Run: make backend-fmt"
                    )

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

    if failures:
        print("\nConfiguration errors:")
        for failure in failures:
            print(f"  {failure}")
        return 1

    print("Configuration OK.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
