#!/usr/bin/env python3
"""Enforce the module boundaries defined in the Phase 0 engineering plan.

Three rules are checked, and all three exist because a boundary that is only written down
erodes within a quarter:

1. Framework purity. No target in ApertureCore may import an Apple framework. This is what
   keeps the domain and sync logic buildable and testable on Linux, which in turn is what
   lets the hardest logic in the product run in CI on a cheap ubuntu runner and on a
   developer's Cloud Shell session.

2. Feature isolation. Feature modules may not import each other and may not import the
   data layer. Cross-feature communication goes through the domain layer.

3. Acyclicity. The target dependency graph must be a DAG.

Written in Python rather than Swift on purpose: it has to run on the Linux pull request
job, where there is no Swift toolchain, and it has to run before anything compiles.

Exit code 0 on success, 1 on any violation.
"""

from __future__ import annotations

import re
import sys
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent
PACKAGES_ROOT = REPO_ROOT / "ios" / "Packages"

# Frameworks that tie code to an Apple platform. Importing any of these inside
# ApertureCore breaks Linux buildability, which is a functional regression and not a
# stylistic one.
APPLE_FRAMEWORKS = {
    "SwiftUI", "UIKit", "AppKit", "SwiftData", "CoreData", "Combine",
    "AVFoundation", "AVKit", "CoreML", "Vision", "VisionKit", "ARKit",
    "RoomPlan", "CoreLocation", "MapKit", "PDFKit", "WidgetKit", "ActivityKit",
    "CryptoKit", "LocalAuthentication", "Security", "MetricKit", "BackgroundTasks",
    "UserNotifications", "CoreImage", "Metal", "os", "OSLog", "Observation",
    "FoundationModels", "CoreAI",
}

PURE_PACKAGE = "ApertureCore"

FORBIDDEN_TARGET_EDGES = [
    # (importer prefix, forbidden import prefix, reason)
    ("Feature", "Feature", "feature modules must not depend on each other"),
    ("Feature", "ApertureData", "features depend on domain protocols, never on the data layer"),
    ("ApertureDomain", "*", "the domain layer depends on nothing"),
]

IMPORT_PATTERN = re.compile(r"^\s*(?:@testable\s+)?import\s+([A-Za-z_][A-Za-z0-9_]*)", re.MULTILINE)
TARGET_PATTERN = re.compile(
    r"\.(?:target|testTarget)\s*\(\s*name:\s*\"([^\"]+)\"(.*?)(?=\n\s*\.(?:target|testTarget)\s*\(|\n\s*\]\s*\)\s*$)",
    re.DOTALL,
)
DEPENDENCY_NAME_PATTERN = re.compile(r"\"([A-Za-z_][A-Za-z0-9_]*)\"")


class Violation:
    def __init__(self, path: Path, rule: str, detail: str) -> None:
        self.path = path
        self.rule = rule
        self.detail = detail

    def __str__(self) -> str:
        relative = self.path.relative_to(REPO_ROOT) if self.path.is_absolute() else self.path
        return f"  {relative}\n      rule: {self.rule}\n      {self.detail}"


def source_files(package: Path) -> list[Path]:
    sources = package / "Sources"
    if not sources.is_dir():
        return []
    return sorted(sources.rglob("*.swift"))


def imports_in(path: Path) -> list[str]:
    text = path.read_text(encoding="utf-8")
    return IMPORT_PATTERN.findall(text)


def check_framework_purity() -> list[Violation]:
    violations: list[Violation] = []
    package = PACKAGES_ROOT / PURE_PACKAGE
    for path in source_files(package):
        for name in imports_in(path):
            if name in APPLE_FRAMEWORKS:
                violations.append(
                    Violation(
                        path,
                        "ApertureCore must build on Linux",
                        f"imports '{name}'. Move this code to AperturePlatform, or express "
                        f"the dependency as a protocol in ApertureDomain and implement it there.",
                    )
                )
    return violations


def parse_targets(manifest: Path) -> dict[str, set[str]]:
    """Extract target -> declared dependency names from a Package.swift."""
    text = manifest.read_text(encoding="utf-8")
    targets: dict[str, set[str]] = {}
    for name, body in TARGET_PATTERN.findall(text + "\n    ]\n)"):
        dependency_block = ""
        marker = body.find("dependencies:")
        if marker != -1:
            opening = body.find("[", marker)
            depth = 0
            for index in range(opening, len(body)):
                if body[index] == "[":
                    depth += 1
                elif body[index] == "]":
                    depth -= 1
                    if depth == 0:
                        dependency_block = body[opening : index + 1]
                        break
        names = set(DEPENDENCY_NAME_PATTERN.findall(dependency_block))
        # Drop package names that appear as `package:` arguments rather than products.
        names -= {"ApertureCore", "AperturePlatform"}
        targets[name] = names
    return targets


def check_feature_isolation() -> list[Violation]:
    violations: list[Violation] = []
    for manifest in sorted(PACKAGES_ROOT.glob("*/Package.swift")):
        for target, dependencies in parse_targets(manifest).items():
            if target.endswith("Tests"):
                continue
            for dependency in sorted(dependencies):
                for importer_prefix, forbidden_prefix, reason in FORBIDDEN_TARGET_EDGES:
                    if not target.startswith(importer_prefix):
                        continue
                    if forbidden_prefix == "*":
                        violations.append(
                            Violation(manifest, "layering", f"{target} declares dependency '{dependency}': {reason}")
                        )
                    elif dependency.startswith(forbidden_prefix) and dependency != target:
                        violations.append(
                            Violation(manifest, "layering", f"{target} depends on {dependency}: {reason}")
                        )
    return violations


def check_acyclic() -> list[Violation]:
    graph: dict[str, set[str]] = {}
    for manifest in sorted(PACKAGES_ROOT.glob("*/Package.swift")):
        graph.update(parse_targets(manifest))

    state: dict[str, int] = {}
    cycles: list[list[str]] = []

    def visit(node: str, stack: list[str]) -> None:
        if state.get(node) == 2:
            return
        if state.get(node) == 1:
            cycles.append(stack[stack.index(node):] + [node])
            return
        state[node] = 1
        for neighbour in sorted(graph.get(node, set())):
            if neighbour in graph:
                visit(neighbour, stack + [neighbour])
        state[node] = 2

    for node in sorted(graph):
        visit(node, [node])

    return [
        Violation(PACKAGES_ROOT, "acyclicity", "dependency cycle: " + " -> ".join(cycle))
        for cycle in cycles
    ]


# Build products and dependency checkouts are not our code. SPM materializes every
# dependency under .build, and a checker that walks them reports findings nobody can act on.
SKIPPED_PARTS = {".build", "checkouts", "DerivedData", ".git"}


def is_ours(path) -> bool:
    return not any(part in SKIPPED_PARTS or part.startswith(".") for part in path.parts)


def main() -> int:
    if not PACKAGES_ROOT.is_dir():
        print(f"error: {PACKAGES_ROOT} not found. Run from the repository root.", file=sys.stderr)
        return 1

    violations = check_framework_purity() + check_feature_isolation() + check_acyclic()

    if violations:
        print("Module boundary violations:\n")
        for violation in violations:
            print(violation)
            print()
        print(f"{len(violations)} violation(s). See docs/adr/0001-two-swift-packages.md for the rules.")
        return 1

    package_count = len(list(PACKAGES_ROOT.glob("*/Package.swift")))
    source_count = sum(len(source_files(PACKAGES_ROOT / p.name)) for p in PACKAGES_ROOT.iterdir() if p.is_dir())
    print(f"Module boundaries OK: {package_count} package(s), {source_count} source file(s) checked.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
