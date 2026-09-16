#!/usr/bin/env bash
# Report what this machine can and cannot build, and why.
#
# Run it after unzipping, after a Cloud Shell VM recycle, or whenever something that
# worked yesterday does not work today. It prints a status table rather than failing, so
# it is safe to run at any time.
set -uo pipefail

cd "$(dirname "$0")/.."

GREEN=$'\033[0;32m'; YELLOW=$'\033[0;33m'; RED=$'\033[0;31m'; BLUE=$'\033[1;34m'; OFF=$'\033[0m'

ok()   { printf "  ${GREEN}yes${OFF}   %-22s %s\n" "$1" "${2:-}"; }
warn() { printf "  ${YELLOW}no${OFF}    %-22s %s\n" "$1" "${2:-}"; }
bad()  { printf "  ${RED}FAIL${OFF}  %-22s %s\n" "$1" "${2:-}"; }
head1(){ printf "\n${BLUE}%s${OFF}\n" "$1"; }

OS="$(uname -s)"
IN_CLOUD_SHELL=false
[[ -d /google/devshell || -n "${CLOUD_SHELL:-}" || -n "${DEVSHELL_PROJECT_ID:-}" ]] && IN_CLOUD_SHELL=true

printf "${BLUE}Aperture environment report${OFF}\n"
printf "  platform: %s   cloud shell: %s\n" "$OS" "$IN_CLOUD_SHELL"

head1 "Toolchains"
command -v git      >/dev/null && ok "git"      "$(git --version | awk '{print $3}')"        || bad  "git"      "required"
command -v python3  >/dev/null && ok "python3"  "$(python3 --version | awk '{print $2}')"    || bad  "python3"  "required for the verification scripts"
command -v swift    >/dev/null && ok "swift"    "$(swift --version 2>&1 | head -1 | sed 's/.*version //;s/ .*//')" \
                                               || warn "swift"    "run ./scripts/cloudshell_setup.sh"
command -v go       >/dev/null && ok "go"       "$(go version | awk '{print $3}')"           || warn "go"       "backend cannot be built here"
command -v docker   >/dev/null && ok "docker"   "$(docker --version | awk '{print $3}' | tr -d ,)" || warn "docker" "local stack unavailable"
command -v gh       >/dev/null && ok "gh"       "$(gh --version | head -1 | awk '{print $3}')" || warn "gh" "run ./scripts/cloudshell_setup.sh"
command -v gcloud   >/dev/null && ok "gcloud"   "$(gcloud version 2>/dev/null | head -1 | awk '{print $4}')" || warn "gcloud" "not needed outside GCP work"
command -v xcodebuild >/dev/null && ok "xcodebuild" "$(xcodebuild -version 2>/dev/null | head -1)" \
                                               || warn "xcodebuild" "macOS only, expected absent on Linux"
command -v xcodegen >/dev/null && ok "xcodegen" || warn "xcodegen" "macOS only: brew install xcodegen"

head1 "What builds on this machine"
if command -v swift >/dev/null; then
  ok "ApertureCore" "domain, sync, contracts. make core-test"
elif command -v docker >/dev/null; then
  ok "ApertureCore" "via container. make core-test-docker"
else
  warn "ApertureCore" "needs the Swift toolchain or Docker"
fi
if [[ "$OS" == "Darwin" ]]; then
  ok "AperturePlatform" "make platform-build"
  ok "app target" "make ios-build"
else
  warn "AperturePlatform" "macOS only. Push and read the ios workflow"
  warn "app target" "macOS only. Push and read the ios workflow"
fi
command -v go >/dev/null && ok "backend" "make backend-test" || warn "backend" "needs Go"
ok "checks" "make check. No toolchain required"

head1 "Repository health"
python3 scripts/check_module_boundaries.py >/dev/null 2>&1 \
  && ok "module boundaries" || bad "module boundaries" "run: make boundaries"
python3 scripts/verify_queue_schema.py >/dev/null 2>&1 \
  && ok "queue schema" || bad "queue schema" "run: make schema"
python3 scripts/validate_configs.py >/dev/null 2>&1 \
  && ok "configuration" || bad "configuration" "run: make lint-config"

EXEC_MISSING=0
for f in scripts/*.sh scripts/*.py; do [[ -x "$f" ]] || EXEC_MISSING=1; done
if [[ $EXEC_MISSING -eq 0 ]]; then
  ok "script permissions"
else
  warn "script permissions" "run: chmod +x scripts/*.sh scripts/*.py"
fi

head1 "Git and remotes"
if [[ -d .git ]]; then
  ok "git repository" "branch $(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo unknown)"
  if git remote get-url origin >/dev/null 2>&1; then
    ok "origin" "$(git remote get-url origin)"
  else
    warn "origin" "no remote yet. See SETUP.md step 7"
  fi
else
  warn "git repository" "not initialized. See SETUP.md step 7"
fi
if command -v gh >/dev/null && gh auth status >/dev/null 2>&1; then
  ok "github auth" "$(gh api user --jq .login 2>/dev/null)"
else
  warn "github auth" "run: gh auth login"
fi

head1 "Google Cloud"
if command -v gcloud >/dev/null; then
  PROJECT="$(gcloud config get-value project 2>/dev/null)"
  [[ -n "$PROJECT" && "$PROJECT" != "(unset)" ]] && ok "project" "$PROJECT" || warn "project" "gcloud config set project ..."
else
  warn "gcloud" "skipped"
fi

printf "\nNext: ${BLUE}make help${OFF}\n"
