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

log "Installing base tools (git, gh, curl, ssh, ...)"
apt_run install -y -qq --no-install-recommends \
  ca-certificates \
  curl \
  fontconfig \
  git \
  gh \
  jq \
  less \
  libfreetype6 \
  libxi6 \
  libxrender1 \
  libxtst6 \
  openssh-server \
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

  case "$(uname -m)" in
    x86_64 | amd64) oc_pkg="cli-linux-x64" ;;
    aarch64 | arm64) oc_pkg="cli-linux-arm64" ;;
    *)
      log "OpenCode: unsupported architecture '$(uname -m)'"
      return 1
      ;;
  esac

  # Use the baseline build on x86 CPUs without AVX2.
  if [ "$oc_pkg" = "cli-linux-x64" ] && ! grep -qwi avx2 /proc/cpuinfo 2>/dev/null; then
    oc_pkg="cli-linux-x64-baseline"
  fi

  # Primary: resolve and download the v2 release straight from the npm registry.
  # This avoids opencode.ai, which is unreachable on some networks.
  oc_base="https://registry.npmjs.org/@opencode/${oc_pkg}"
  ver="$(curl -4 -fsSL --retry 5 --retry-all-errors --retry-delay 3 --connect-timeout 15 --max-time 60 \
    "$oc_base/latest" 2>/dev/null | sed -n 's/.*"version":"\([^"]*\)".*/\1/p' | head -n1)"

  if [ -n "$ver" ]; then
    tmp="$(mktemp -d)"
    if curl -4 -fsSL --retry 5 --retry-all-errors --retry-delay 3 --connect-timeout 15 --max-time 300 \
      "$oc_base/-/${oc_pkg}-${ver}.tgz" -o "$tmp/oc.tgz" 2>/dev/null &&
      tar -xzf "$tmp/oc.tgz" -C "$tmp" 2>/dev/null &&
      [ -f "$tmp/package/bin/opencode" ]; then
      install -m 0755 "$tmp/package/bin/opencode" /usr/local/bin/opencode
      rm -rf "$tmp"
      return 0
    fi
    rm -rf "$tmp"
  fi

  # Fallback: the official installer.
  tmp_installer="$(mktemp)"
  if curl -4 -fsSL --retry 3 --retry-all-errors --retry-delay 3 --connect-timeout 15 --max-time 120 \
    https://opencode.ai/v2/install -o "$tmp_installer" 2>/dev/null &&
    bash "$tmp_installer" --no-modify-path >/dev/null 2>&1 &&
    [ -x "$HOME/.opencode/bin/opencode" ]; then
    install -m 0755 "$HOME/.opencode/bin/opencode" /usr/local/bin/opencode
    rm -f "$tmp_installer"
    return 0
  fi
  rm -f "$tmp_installer"
  return 1
}

if install_opencode; then
  log "OpenCode installed ($(/usr/local/bin/opencode --version 2>/dev/null || echo unknown))"
else
  log "OpenCode install skipped"
fi

# SSH: allow key-based root login so JetBrains Remote Development (and cage ssh)
# can attach. Password auth stays disabled.
log "Configuring SSH"
install -d -m 700 /root/.ssh
mkdir -p /etc/ssh/sshd_config.d
cat > /etc/ssh/sshd_config.d/10-cage.conf <<'EOF'
PermitRootLogin prohibit-password
PasswordAuthentication no
PubkeyAuthentication yes
EOF
if command -v systemctl >/dev/null 2>&1; then
  systemctl enable ssh >/dev/null 2>&1 || true
  systemctl restart ssh >/dev/null 2>&1 || systemctl restart sshd >/dev/null 2>&1 || true
else
  service ssh restart >/dev/null 2>&1 || true
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
