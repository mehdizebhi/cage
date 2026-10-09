#!/bin/sh
#
# Cage installer.
#
# Downloads the latest (or a specific) Cage release for the current
# Linux system and installs the `cage` binary into a directory on PATH.
#
# Usage:
#   curl -fsSL https://raw.githubusercontent.com/mehdizebhi/cage/main/install.sh | sh
#
#   ./install.sh --version v0.1.0 --dir ~/.local/bin
#
set -eu

REPO="${CAGE_REPO:-mehdizebhi/cage}"
VERSION="${CAGE_VERSION:-latest}"
INSTALL_DIR="${CAGE_INSTALL_DIR:-}"

usage() {
  cat <<'EOF'
Cage installer

Usage: install.sh [options]

Options:
  -v, --version <tag>   Install a specific release tag (e.g. v0.1.0).
                        Default: latest
  -d, --dir <path>      Install directory. Default: $HOME/.local/bin
  -h, --help            Show this help message

Environment:
  CAGE_VERSION          Same as --version
  CAGE_INSTALL_DIR      Same as --dir
  CAGE_REPO             Override the GitHub repo (owner/name)
  CAGE_BASE_URL         Override the download base URL

Requirements:
  curl (or wget), tar, and a Linux host (Cage drives Incus).
EOF
}

while [ $# -gt 0 ]; do
  case "$1" in
    -v|--version)
      [ $# -ge 2 ] || { echo "install.sh: $1 requires a value" >&2; exit 2; }
      VERSION="$2"
      shift 2
      ;;
    --version=*)
      VERSION="${1#*=}"
      shift
      ;;
    -d|--dir)
      [ $# -ge 2 ] || { echo "install.sh: $1 requires a value" >&2; exit 2; }
      INSTALL_DIR="$2"
      shift 2
      ;;
    --dir=*)
      INSTALL_DIR="${1#*=}"
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "install.sh: unknown option '$1'" >&2
      usage >&2
      exit 2
      ;;
  esac
done

if [ -z "$INSTALL_DIR" ]; then
  INSTALL_DIR="$HOME/.local/bin"
fi

# --- Detect platform ---------------------------------------------------------

os="$(uname -s)"
case "$os" in
  Linux) ;;
  *)
    echo "cage: unsupported OS '$os'. Cage requires Linux with Incus." >&2
    exit 1
    ;;
esac

arch="$(uname -m)"
case "$arch" in
  x86_64|amd64) target="x86_64" ;;
  aarch64|arm64) target="aarch64" ;;
  *)
    echo "cage: unsupported architecture '$arch'." >&2
    exit 1
    ;;
esac

asset="cage-linux-${target}.tar.gz"

if [ "$VERSION" = "latest" ]; then
  base="https://github.com/${REPO}/releases/latest/download"
else
  base="https://github.com/${REPO}/releases/download/${VERSION}"
fi

# Allow overriding the download base (mirrors, self-hosting, testing).
if [ -n "${CAGE_BASE_URL:-}" ]; then
  base="$CAGE_BASE_URL"
fi

echo "cage: installing ${VERSION} for linux-${target}"

# --- Helpers -----------------------------------------------------------------

tmpdir="$(mktemp -d)"
trap 'rm -rf "$tmpdir"' EXIT INT TERM

download() {
  # download <url> <output>
  url="$1"
  out="$2"
  if command -v curl >/dev/null 2>&1; then
    curl -fsSL "$url" -o "$out"
  elif command -v wget >/dev/null 2>&1; then
    wget -qO "$out" "$url"
  else
    echo "cage: need 'curl' or 'wget' to download releases." >&2
    exit 1
  fi
}

sha256() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | awk '{print $1}'
  elif command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$1" | awk '{print $1}'
  else
    return 1
  fi
}

# --- Download ----------------------------------------------------------------

download "${base}/${asset}" "${tmpdir}/${asset}"

# Verify against checksums.txt when available (best effort).
if download "${base}/checksums.txt" "${tmpdir}/checksums.txt" 2>/dev/null; then
  expected="$(awk -v a="$asset" '{ n=$2; sub(/^\*/, "", n); sub(/^\.\//, "", n); if (n == a) { print $1; exit } }' "${tmpdir}/checksums.txt" || true)"
  if [ -n "$expected" ]; then
    actual="$(sha256 "${tmpdir}/${asset}")" || {
      echo "cage: no sha256 tool available; skipping checksum verification" >&2
      actual=""
    }
    if [ -n "$actual" ] && [ "$actual" != "$expected" ]; then
      echo "cage: checksum mismatch for ${asset}" >&2
      echo "  expected: ${expected}" >&2
      echo "  actual:   ${actual}" >&2
      exit 1
    fi
    [ -n "$actual" ] && echo "cage: checksum verified"
  fi
fi

# --- Install -----------------------------------------------------------------

tar -xzf "${tmpdir}/${asset}" -C "${tmpdir}"

if [ ! -f "${tmpdir}/cage" ]; then
  echo "cage: release archive did not contain a 'cage' binary" >&2
  exit 1
fi

mkdir -p "$INSTALL_DIR"
install -m 0755 "${tmpdir}/cage" "${INSTALL_DIR}/cage"

echo "cage: installed to ${INSTALL_DIR}/cage"

# --- PATH hint ---------------------------------------------------------------

case ":${PATH}:" in
  *":${INSTALL_DIR}:"*) ;;
  *)
    echo ""
    echo "Add ${INSTALL_DIR} to your PATH:"
    echo "  export PATH=\"${INSTALL_DIR}:\$PATH\""
    ;;
esac

echo ""
"${INSTALL_DIR}/cage" version
