#!/usr/bin/env bash
# Fill the Homebrew formula's binary sha256s from a published release and copy it
# into the tap repo. Usage: scripts/update-tap.sh <version> [tap-checkout-dir]
#   e.g. scripts/update-tap.sh 0.2.0 ../homebrew-fast-mempalace
set -euo pipefail
VERSION="${1:?usage: update-tap.sh <version> [tap-dir]}"
TAP_DIR="${2:-../homebrew-fast-mempalace}"
REPO="${FAST_MEMPALACE_REPO:-debpalash/fast-mempalace}"
SRC="packaging/homebrew/fast-mempalace.rb"
BASE="https://github.com/$REPO/releases/download/v$VERSION"

tmp=$(mktemp); cp "$SRC" "$tmp"
declare -A MAP=(
  [REPLACE_DARWIN_AARCH64]=darwin-aarch64
  [REPLACE_DARWIN_X86_64]=darwin-x86_64
  [REPLACE_LINUX_AARCH64]=linux-aarch64
  [REPLACE_LINUX_X86_64]=linux-x86_64
)
for ph in "${!MAP[@]}"; do
  plat="${MAP[$ph]}"
  sha=$(curl -fsSL "$BASE/fast-mempalace-$plat.tar.gz.sha256" | awk '{print $1}') \
    || { echo "warn: no artifact for $plat (skipping)"; continue; }
  sed -i '' "s/$ph/$sha/" "$tmp" 2>/dev/null || sed -i "s/$ph/$sha/" "$tmp"
  echo "  $plat -> $sha"
done
sed -i '' "s/version \"[^\"]*\"/version \"$VERSION\"/" "$tmp" 2>/dev/null || sed -i "s/version \"[^\"]*\"/version \"$VERSION\"/" "$tmp"

mkdir -p "$TAP_DIR/Formula"
cp "$tmp" "$TAP_DIR/Formula/fast-mempalace.rb"
echo "Wrote $TAP_DIR/Formula/fast-mempalace.rb"
