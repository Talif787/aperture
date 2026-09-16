#!/usr/bin/env bash
# Prepare a Google Cloud Shell session for Aperture development.
#
# Cloud Shell gives you a persistent $HOME of about 5 GB and an ephemeral VM. Anything
# installed with apt outside $HOME disappears when the VM recycles, which happens after
# about an hour of inactivity. Tools therefore install into $HOME, and
# ~/.customize_environment re-runs on every VM boot to restore anything that cannot.
#
# Run once:  ./scripts/cloudshell_setup.sh
set -euo pipefail

TOOLS_DIR="${HOME}/.aperture-tools"
PROFILE="${HOME}/.bashrc"

log() { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m!! \033[0m %s\n' "$*"; }

if [[ ! -d /google/devshell ]] && [[ -z "${CLOUD_SHELL:-}" ]]; then
  warn "This does not look like Cloud Shell. Continuing anyway."
fi

mkdir -p "${TOOLS_DIR}"

log "Checking preinstalled tooling"
for tool in git go docker python3 gcloud; do
  if command -v "${tool}" >/dev/null 2>&1; then
    printf '    %-8s %s\n' "${tool}" "$(command -v "${tool}")"
  else
    warn "${tool} not found on PATH"
  fi
done

log "Installing GitHub CLI if absent"
if ! command -v gh >/dev/null 2>&1; then
  # Installed into $HOME so it survives a VM recycle.
  GH_VERSION="2.63.2"
  curl -fsSL "https://github.com/cli/cli/releases/download/v${GH_VERSION}/gh_${GH_VERSION}_linux_amd64.tar.gz" \
    | tar -xz -C "${TOOLS_DIR}" --strip-components=1 "gh_${GH_VERSION}_linux_amd64/bin/gh"
  log "gh installed to ${TOOLS_DIR}/gh"
else
  log "gh already present"
fi

log "Installing the Swift toolchain via swiftly"
# swiftly is Apple's official toolchain installer. It detects the host platform, which
# matters here because Cloud Shell is Debian rather than Ubuntu, and it reports any missing
# system packages rather than failing with a linker error later.
#
# It installs into $HOME, so it survives a Cloud Shell VM recycle.
#
# This builds and tests ApertureCore only. The Apple frameworks used by AperturePlatform
# and the app target do not exist on Linux, and no toolchain changes that. Those build on
# macOS, on a Mac or on the macOS CI runner.
SWIFTLY_VERSION="${SWIFTLY_VERSION:-1.1.2}"
SWIFTLY_BIN="${HOME}/.local/share/swiftly/bin/swiftly"

FREE_KB=$(df -Pk "${HOME}" | awk 'NR==2 {print $4}')
if (( FREE_KB < 4000000 )); then
  warn "Only $((FREE_KB / 1024)) MB free in \$HOME. A Swift toolchain needs roughly 3 GB."
  warn "Free space first, or skip Swift and let CI build ApertureCore for you."
  warn "  du -sh ~/* | sort -h | tail       # find the large directories"
  warn "  docker system prune -af           # reclaim Docker layers"
fi

if command -v swift >/dev/null 2>&1; then
  log "Swift already present: $(swift --version 2>&1 | head -1)"
elif [[ -x "${SWIFTLY_BIN}" ]]; then
  log "swiftly already installed, installing the latest toolchain"
  "${SWIFTLY_BIN}" install latest --use --assume-yes || warn "toolchain install failed, see the output above"
else
  TMP="$(mktemp -d)"
  ARCH="$(uname -m)"
  (
    cd "${TMP}"
    log "Downloading swiftly ${SWIFTLY_VERSION} for ${ARCH}"
    curl -fLO "https://download.swift.org/swiftly/linux/swiftly-${SWIFTLY_VERSION}-${ARCH}.tar.gz"
    tar -zxf "swiftly-${SWIFTLY_VERSION}-${ARCH}.tar.gz"
    log "Running swiftly init, which installs the latest stable toolchain"
    ./swiftly init --assume-yes --quiet-shell-followup
  ) || warn "swiftly install failed. See the manual fallback in SETUP.md step 4."
  rm -rf "${TMP}"

  ENV_FILE="${HOME}/.local/share/swiftly/env.sh"
  # shellcheck disable=SC1090
  [[ -f "${ENV_FILE}" ]] && . "${ENV_FILE}"
fi

log "Writing ~/.customize_environment so tools survive a VM recycle"
cat > "${HOME}/.customize_environment" <<'CUSTOMIZE'
#!/bin/sh
# Runs as root on every Cloud Shell VM boot. Keep it fast: Cloud Shell will not wait long.
# Anything installed under $HOME persists on its own; this is only for system packages.
apt-get -o DPkg::Lock::Timeout=60 update -qq || true
apt-get -o DPkg::Lock::Timeout=60 install -y -qq \
  libcurl4-openssl-dev libxml2-dev libsqlite3-dev >/dev/null 2>&1 || true
CUSTOMIZE
chmod +x "${HOME}/.customize_environment"

log "Adding tools to PATH in ${PROFILE}"
MARKER="# aperture-tools"
if ! grep -q "${MARKER}" "${PROFILE}" 2>/dev/null; then
  cat >> "${PROFILE}" <<EOF

${MARKER}
export PATH="\${HOME}/.aperture-tools:\${PATH}"
export APERTURE_ROOT="\${HOME}/aperture"
# swiftly writes its own env file; source it when present so swift is on PATH
[ -f "\${HOME}/.local/share/swiftly/env.sh" ] && . "\${HOME}/.local/share/swiftly/env.sh"
EOF
  log "PATH updated. Run: source ${PROFILE}"
else
  log "PATH entry already present"
fi

log "Configuring git identity if unset"
if [[ -z "$(git config --global user.email || true)" ]]; then
  warn "git user.email is unset. Run:"
  echo "    git config --global user.email \"you@example.com\""
  echo "    git config --global user.name  \"Your Name\""
fi
git config --global init.defaultBranch main
git config --global pull.rebase true
git config --global push.autoSetupRemote true
git config --global core.editor "nano"

log "Done. Next:"
echo "    source ${PROFILE}"
echo "    swift --version        # confirms the Linux toolchain"
echo "    make core-test         # builds and tests ApertureCore on Linux"
