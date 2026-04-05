#!/usr/bin/env bash
# Start the OpenShell plaintext gateway.
# Uses the native openshell CLI if available, otherwise runs it in Docker.
# The gateway listens on port 8080 (plaintext, no TLS).

set -e

GATEWAY_CONTAINER_NAME="ampersend-gateway"
MIN_OPENSHELL_VERSION="0.0.20"

# Check if gateway is already running
if docker ps --format '{{.Names}}' 2>/dev/null | grep -q "openshell-cluster-openshell"; then
  echo "Gateway is already running (openshell-cluster-openshell container found)."
  echo "To stop it: openshell gateway stop  (or docker stop openshell-cluster-openshell)"
  exit 0
fi

# version_gte returns 0 if $1 >= $2 (dotted version comparison)
version_gte() {
  printf '%s\n%s\n' "$2" "$1" | sort -V | head -1 | grep -qx "$2"
}

if command -v openshell &>/dev/null; then
  OPENSHELL_VER=$(openshell --version 2>/dev/null | awk '{print $NF}')
  if ! version_gte "$OPENSHELL_VER" "$MIN_OPENSHELL_VERSION"; then
    echo "WARNING: openshell $OPENSHELL_VER is installed but >= $MIN_OPENSHELL_VERSION is required."
    echo "Older versions cause gRPC 'Unimplemented' errors with new gateway images."
    echo ""
    echo "Upgrade with:  uv tool install -U openshell"
    echo "  (then ensure ~/.local/bin is in your PATH, or re-run this script)"
    echo ""
    # Check if a newer version exists in ~/.local/bin (installed via uv)
    if [[ -x "$HOME/.local/bin/openshell" ]]; then
      UV_VER=$("$HOME/.local/bin/openshell" --version 2>/dev/null | awk '{print $NF}')
      if version_gte "$UV_VER" "$MIN_OPENSHELL_VERSION"; then
        echo "Found openshell $UV_VER at ~/.local/bin/openshell — using that instead."
        export PATH="$HOME/.local/bin:$PATH"
        OPENSHELL_VER="$UV_VER"
      else
        echo "Falling back to Docker-based gateway."
      fi
    fi
  fi

  if version_gte "$OPENSHELL_VER" "$MIN_OPENSHELL_VERSION"; then
    echo "Starting gateway using native openshell CLI (v$OPENSHELL_VER)..."
    openshell gateway destroy 2>/dev/null || true
    openshell gateway start --plaintext
    echo ""
    echo "Gateway started on port 8080 (plaintext)."
    echo "Stop with: openshell gateway stop"
    exit 0
  fi
  echo "Falling back to Docker-based gateway (installs latest openshell)..."
fi

# Docker fallback: openshell not found or version too old
if ! command -v docker &>/dev/null; then
  echo "ERROR: Docker is required. Install Docker Desktop and try again."
  exit 1
fi

docker rm -f "$GATEWAY_CONTAINER_NAME" 2>/dev/null || true

docker run --rm \
  --name "$GATEWAY_CONTAINER_NAME" \
  --cgroupns=host \
  -v "/var/run/docker.sock:/var/run/docker.sock" \
  -w /workspace \
  ubuntu:24.04 \
  bash -c '
    set -e
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -qq && apt-get install -y -qq curl ca-certificates docker.io > /dev/null

    curl -LsSf https://astral.sh/uv/install.sh | sh
    export PATH="$HOME/.local/bin:$PATH"
    uv tool install -U openshell

    openshell gateway destroy 2>/dev/null || true

    echo "Starting OpenShell gateway (plaintext, port 8080)..."
    openshell gateway start --plaintext
  '

echo ""
echo "Gateway started on port 8080 (plaintext) via Docker."
echo "Stop with: docker stop openshell-cluster-openshell"
