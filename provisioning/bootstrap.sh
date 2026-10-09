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

# OpenCode: install the release binary from GitHub. This is a stable, versioned
# source that does not depend on the (sometimes unreachable) opencode.ai
# installer endpoint. The binary is placed in /usr/local/bin so it is on PATH
# for every user and every login shell.
log "Installing OpenCode"
install_opencode() {
  command -v opencode >/dev/null 2>&1 && return 0

  case "$(uname -m)" in
    x86_64 | amd64) asset="opencode-linux-x64.tar.gz" ;;
    aarch64 | arm64) asset="opencode-linux-arm64.tar.gz" ;;
    *)
      log "OpenCode: unsupported architecture '$(uname -m)'"
      return 1
      ;;
  esac

  repo="${OPENCODE_REPO:-anomalyco/opencode}"
  url="https://github.com/${repo}/releases/latest/download/${asset}"
  tmp="$(mktemp -d)"

  if curl -fsSL --retry 3 --max-time 300 "$url" -o "$tmp/opencode.tar.gz" &&
    tar -xzf "$tmp/opencode.tar.gz" -C "$tmp" &&
    [ -f "$tmp/opencode" ]; then
    install -m 0755 "$tmp/opencode" /usr/local/bin/opencode
    rm -rf "$tmp"
    return 0
  fi

  rm -rf "$tmp"
  return 1
}

if install_opencode; then
  log "OpenCode installed ($(opencode --version 2>/dev/null || echo unknown))"
elif command -v npm >/dev/null 2>&1; then
  log "Falling back to npm for OpenCode"
  npm install -g opencode-ai || log "OpenCode install skipped"
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
