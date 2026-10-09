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

log "Updating apt package lists"
apt-get update -qq

log "Installing base tools (git, gh, curl, ...)"
apt-get install -y -qq --no-install-recommends \
  ca-certificates \
  curl \
  git \
  gh \
  jq \
  less \
  procps \
  sudo \
  unzip \
  vim-tiny \
  xz-utils

# OpenCode: prefer the official installer, fall back to npm when available.
log "Installing OpenCode"
if ! command -v opencode >/dev/null 2>&1; then
  if ! curl -fsSL https://opencode.ai/install | bash; then
    if command -v npm >/dev/null 2>&1; then
      npm install -g opencode-ai || log "OpenCode install skipped"
    else
      log "OpenCode install skipped (no installer access and npm missing)"
    fi
  fi
fi

install_stack() {
  case "$1" in
    node)
      log "Installing Node.js"
      curl -fsSL https://deb.nodesource.com/setup_22.x | bash - >/dev/null
      apt-get install -y -qq nodejs
      ;;
    python)
      log "Installing Python"
      apt-get install -y -qq python3 python3-pip python3-venv
      ;;
    java)
      log "Installing Java"
      apt-get install -y -qq default-jdk
      ;;
    go)
      log "Installing Go"
      apt-get install -y -qq golang-go
      ;;
    rust)
      log "Installing Rust"
      apt-get install -y -qq rustc cargo
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
