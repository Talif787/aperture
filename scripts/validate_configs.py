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

    if failures:
        print("\nConfiguration errors:")
        for failure in failures:
            print(f"  {failure}")
        return 1

    print("Configuration OK.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
