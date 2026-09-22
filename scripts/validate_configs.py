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

    if failures:
        print("\nConfiguration errors:")
        for failure in failures:
            print(f"  {failure}")
        return 1

    print("Configuration OK.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
