#!/usr/bin/env bash
# memxt installer — fetches prebuilt native binary + embedding model.
#
# Usage:
#   curl -fsSL https://raw.githubusercontent.com/Yupcha/memxt/main/install.sh | bash
#
# Env overrides:
#   MEMXT_VERSION   Release tag to install (default: latest)
#   MEMXT_INSTALL   Install prefix (default: $HOME/.memxt)
#   MEMXT_REPO      GitHub repo (default: Yupcha/memxt)
#   MEMXT_NO_MODEL  Skip GGUF embedding model download (default: 0)

set -euo pipefail

TMP_DIR=""
trap '[ -n "$TMP_DIR" ] && rm -rf "$TMP_DIR"' EXIT

REPO="${MEMXT_REPO:-Yupcha/memxt}"
VERSION="${MEMXT_VERSION:-latest}"
INSTALL_DIR="${MEMXT_INSTALL:-$HOME/.memxt}"
BIN_DIR="$INSTALL_DIR/bin"
LIB_DIR="$INSTALL_DIR/lib"
# MiniLM-L6-v2, 384-dim (matches EMBEDDING_DIM and the vec_drawers schema).
# Must stay a 384-dim model or fresh installs fail the dimension check.
MODEL_URL="https://huggingface.co/leliuga/all-MiniLM-L6-v2-GGUF/resolve/main/all-MiniLM-L6-v2.F16.gguf"

C_RESET='\033[0m'; C_BOLD='\033[1m'; C_DIM='\033[2m'
C_BLUE='\033[34m'; C_GREEN='\033[32m'; C_RED='\033[31m'; C_YELLOW='\033[33m'

info()  { printf "%b==>%b %s\n" "$C_BLUE$C_BOLD" "$C_RESET" "$*"; }
warn()  { printf "%bwarn:%b %s\n" "$C_YELLOW$C_BOLD" "$C_RESET" "$*" >&2; }
ok()    { printf "%b✓%b %s\n" "$C_GREEN$C_BOLD" "$C_RESET" "$*"; }
die()   { printf "%berror:%b %s\n" "$C_RED$C_BOLD" "$C_RESET" "$*" >&2; exit 1; }

need() { command -v "$1" >/dev/null 2>&1 || die "missing required command: $1"; }

detect_platform() {
  local os arch
  os=$(uname -s | tr '[:upper:]' '[:lower:]')
  arch=$(uname -m)

  case "$os" in
    darwin) os="darwin" ;;
    linux)  os="linux" ;;
    *)      die "unsupported OS: $os" ;;
  esac

  case "$arch" in
    x86_64|amd64) arch="x86_64" ;;
    arm64|aarch64) arch="aarch64" ;;
    *) die "unsupported arch: $arch" ;;
  esac

  printf "%s-%s" "$os" "$arch"
}

resolve_version() {
  if [ "$VERSION" = "latest" ]; then
    need curl
    VERSION=$(curl -fsSL "https://api.github.com/repos/$REPO/releases/latest" \
      | grep -oE '"tag_name":[[:space:]]*"[^"]+"' \
      | head -n1 \
      | sed -E 's/.*"([^"]+)"$/\1/')
    [ -n "$VERSION" ] || die "could not resolve latest release tag from $REPO"
  fi
}

download() {
  local url="$1" out="$2"
  info "fetching $url"
  curl -fL --progress-bar -o "$out" "$url" || die "download failed: $url"
}

install_binary() {
  local platform="$1"
  local tarball="memxt-${platform}.tar.gz"
  local url="https://github.com/$REPO/releases/download/$VERSION/$tarball"
  TMP_DIR=$(mktemp -d)  # global so the EXIT trap can clean it after main returns

  mkdir -p "$BIN_DIR"
  download "$url" "$TMP_DIR/$tarball"
  tar -xzf "$TMP_DIR/$tarball" -C "$TMP_DIR"
  [ -f "$TMP_DIR/memxt" ] || die "tarball missing 'memxt' binary"
  install -m 755 "$TMP_DIR/memxt" "$BIN_DIR/memxt"
  ok "installed $BIN_DIR/memxt"
}

install_model() {
  if [ "${MEMXT_NO_MODEL:-0}" = "1" ]; then
    warn "skipping embedding model download (MEMXT_NO_MODEL=1)"
    return
  fi
  mkdir -p "$LIB_DIR"
  if [ -f "$LIB_DIR/minilm.gguf" ]; then
    ok "embedding model already present at $LIB_DIR/minilm.gguf"
    return
  fi
  download "$MODEL_URL" "$LIB_DIR/minilm.gguf"
  ok "embedding model saved to $LIB_DIR/minilm.gguf"
}

shell_hint() {
  local shell_rc shell_name
  shell_name=$(basename "${SHELL:-/bin/bash}")
  case "$shell_name" in
    zsh)  shell_rc="$HOME/.zshrc" ;;
    bash) shell_rc="$HOME/.bashrc" ;;
    fish) shell_rc="$HOME/.config/fish/config.fish" ;;
    *)    shell_rc="your shell rc file" ;;
  esac

  echo
  printf "%bmemxt installed to%b %s\n" "$C_BOLD" "$C_RESET" "$INSTALL_DIR"
  echo
  printf "%bNext step:%b add to PATH\n\n" "$C_BOLD" "$C_RESET"
  if [ "$shell_name" = "fish" ]; then
    printf "  fish_add_path %s\n\n" "$BIN_DIR"
  else
    printf "  echo 'export PATH=\"%s:\$PATH\"' >> %s\n" "$BIN_DIR" "$shell_rc"
    printf "  source %s\n\n" "$shell_rc"
  fi
  printf "%bQuick check:%b\n\n  memxt stats\n\n" "$C_BOLD" "$C_RESET"
  printf "%bClaude Code:%b add persistent memory in two lines —\n\n  /plugin marketplace add Yupcha/memxt\n  /plugin install memxt\n\n" \
    "$C_BOLD" "$C_RESET"
  printf "%bSeed memory from a repo (optional):%b\n\n  memxt mine . my-project\n\n" "$C_BOLD" "$C_RESET"
  printf "%bDocs:%b https://github.com/%s\n" "$C_DIM" "$C_RESET" "$REPO"
}

main() {
  need curl
  need tar
  need uname
  need grep

  info "detecting platform"
  local platform
  platform=$(detect_platform)
  ok "platform: $platform"

  info "resolving version"
  resolve_version
  ok "version: $VERSION"

  install_binary "$platform"
  install_model
  shell_hint
}

main "$@"
