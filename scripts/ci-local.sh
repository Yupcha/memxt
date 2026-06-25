#!/usr/bin/env bash
# Run the GitHub Actions Ubuntu CI leg locally via Docker.
#
# Usage:
#   ./scripts/ci-local.sh            # build + stats smoke test
#   ./scripts/ci-local.sh shell      # drop into interactive shell instead
#
# Requires: Docker daemon running.

set -euo pipefail

cd "$(dirname "$0")/.."

IMAGE="memxt-ci:local"

echo "==> Building CI image from Dockerfile.ci"
docker build -f Dockerfile.ci -t "$IMAGE" .

mode="${1:-run}"
case "$mode" in
  run)
    echo "==> Running smoke test (memxt stats)"
    docker run --rm "$IMAGE"
    ;;
  shell)
    echo "==> Opening shell in CI image"
    docker run --rm -it "$IMAGE" /bin/bash
    ;;
  *)
    echo "unknown mode: $mode (use run | shell)" >&2
    exit 2
    ;;
esac
