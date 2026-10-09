#!/usr/bin/env bash
#
# Cage base provisioning script.
#
# Runs as root inside a freshly launched Debian VM. Installs the common
# agentic-development tooling and, optionally, development stacks requested
# by the caller.
#
# Usage: bootstrap.sh [node] [python] [java] [go] [rust]
#
set -euo pipefail

export DEBIAN_FRONTEND=noninteractive

log() { printf '  [cage] %s\n' "$*"; }

APT_LOG=/var/log/cage-apt.log

# Runs apt-get quietly, replaying the log tail only on failure.
apt_run() {
  if ! apt-get "$@" >>"$APT_LOG" 2>&1; then
    printf '  [cage] apt-get %s failed; last lines:\n' "$*" >&2
    tail -n 20 "$APT_LOG" >&2
    return 1
  fi
}

log "Updating apt package lists"
apt_run update -qq

log "Installing base tools (git, gh, curl, ...)"
apt_run install -y -qq --no-install-recommends \
  ca-certificates \
  curl \
  git \
  gh \
  jq \
  less \
  procps \
  ripgrep \
  sudo \
  unzip \
  vim-tiny \
  xz-utils

# OpenCode v2: use the official installer (which resolves the latest v2 release
# from the npm registry), then place the binary on the system PATH so it works
# for every shell and every `incus exec` invocation, not just interactive logins.
log "Installing OpenCode"
install_opencode() {
  command -v opencode >/dev/null 2>&1 && return 0

  tmp_installer="$(mktemp)"
  if ! curl -fsSL --retry 3 --connect-timeout 15 --max-time 180 \
    https://opencode.ai/v2/install -o "$tmp_installer"; then
    rm -f "$tmp_installer"
    log "OpenCode: could not fetch the installer"
    return 1
  fi

  if ! bash "$tmp_installer" --no-modify-path >/dev/null 2>&1; then
    rm -f "$tmp_installer"
    log "OpenCode: installer failed"
    return 1
  fi
  rm -f "$tmp_installer"

  if [ -x "$HOME/.opencode/bin/opencode" ]; then
    install -m 0755 "$HOME/.opencode/bin/opencode" /usr/local/bin/opencode
    return 0
  fi
  return 1
}

if install_opencode; then
  log "OpenCode installed ($(/usr/local/bin/opencode --version 2>/dev/null || echo unknown))"
else
  log "OpenCode install skipped"
fi

install_stack() {
  case "$1" in
    node)
      log "Installing Node.js"
      curl -fsSL --max-time 120 https://deb.nodesource.com/setup_22.x | bash - >>"$APT_LOG" 2>&1
      apt_run install -y -qq nodejs
      ;;
    python)
      log "Installing Python"
      apt_run install -y -qq python3 python3-pip python3-venv
      ;;
    java)
      log "Installing Java"
      apt_run install -y -qq default-jdk
      ;;
    go)
      log "Installing Go"
      apt_run install -y -qq golang-go
      ;;
    rust)
      log "Installing Rust"
      apt_run install -y -qq rustc cargo
      ;;
    *)
      log "Unknown stack '$1' (ignored)"
      ;;
  esac
}

for stack in "$@"; do
  install_stack "$stack"
done

log "Provisioning complete"
