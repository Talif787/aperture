#!/usr/bin/env bash
# Take a fresh clone to a working development environment.
#
# Target: under five minutes on a clean machine. A reviewer who cannot run the project in
# five minutes will not spend twenty more reading it, and a new engineer who spends a day
# on setup has learned nothing about the system.
set -euo pipefail

cd "$(dirname "$0")/.."

log() { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m!! \033[0m %s\n' "$*"; }
fail() { printf '\033[1;31mxx \033[0m %s\n' "$*"; exit 1; }

OS="$(uname -s)"
log "Platform: ${OS}"

command -v python3 >/dev/null 2>&1 || fail "python3 is required for the boundary and schema checks"

if command -v swift >/dev/null 2>&1; then
  log "Swift: $(swift --version 2>&1 | head -1)"
else
  warn "No Swift toolchain. ApertureCore cannot be built here."
  [[ "${OS}" == "Linux" ]] && warn "On Cloud Shell, see SETUP.md and run ./scripts/cloudshell_setup.sh first."
fi

if [[ "${OS}" == "Darwin" ]]; then
  command -v xcodebuild >/dev/null 2>&1 || warn "Xcode not found: the app target cannot be built"
  if ! command -v xcodegen >/dev/null 2>&1; then
    warn "XcodeGen not found. Install with: brew install xcodegen"
  else
    log "Generating Aperture.xcodeproj from ios/project.yml"
    (cd ios && xcodegen generate --quiet)
  fi
else
  log "Not macOS: skipping Xcode project generation (the app target builds on macOS only)"
fi

if command -v go >/dev/null 2>&1; then
  log "Go: $(go version)"
  (cd backend && go mod download >/dev/null 2>&1 || warn "go mod download failed; check network")
else
  warn "Go not found: the backend cannot be built here"
fi

log "Verifying module boundaries"
python3 scripts/check_module_boundaries.py

log "Verifying the sync queue schema"
python3 scripts/verify_queue_schema.py

if [[ ! -f .env ]] && [[ -f .env.example ]]; then
  cp .env.example .env
  log "Created .env from .env.example"
fi

log "Bootstrap complete. Try:"
echo "    make help"
echo "    make check          # everything that runs without a Swift or Go toolchain"
echo "    make core-test      # ApertureCore on Linux or macOS"
echo "    make backend-up     # Postgres and the service in Docker"
