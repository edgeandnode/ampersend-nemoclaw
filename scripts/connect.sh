#!/usr/bin/env bash
# Connect to the sandbox from your Mac.
# Uses native openshell if available, otherwise runs openshell inside Docker.
# The sandbox is a k3s pod managed by the gateway, not a standalone Docker container.

set -e

SANDBOX_NAME="${SANDBOX_NAME:-my-assistant}"

# Try openshell CLI first (if installed natively)
if command -v openshell &>/dev/null; then
  echo "Connecting to sandbox '$SANDBOX_NAME' via openshell..."
  exec openshell sandbox connect "$SANDBOX_NAME"
fi

# Fall back to running openshell inside Docker
if ! command -v docker &>/dev/null; then
  echo "ERROR: Neither openshell nor docker found. Install Docker Desktop or openshell CLI."
  exit 1
fi

# Check that the gateway is running
if ! docker ps --format '{{.Names}}' 2>/dev/null | grep -q "openshell-cluster-openshell"; then
  echo "ERROR: OpenShell gateway is not running."
  echo "Start it first:  npm run gateway:start"
  exit 1
fi

echo "Connecting to sandbox '$SANDBOX_NAME' via openshell in Docker..."

exec docker run --rm -it \
  --cgroupns=host \
  -v "/var/run/docker.sock:/var/run/docker.sock" \
  ubuntu:24.04 \
  bash -c '
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -qq && apt-get install -y -qq curl ca-certificates docker.io > /dev/null
    curl -LsSf https://astral.sh/uv/install.sh | sh 2>/dev/null
    export PATH="$HOME/.local/bin:$PATH"
    uv tool install -U openshell 2>/dev/null
    openshell gateway add http://host.docker.internal:8080 --local 2>/dev/null
    exec openshell sandbox connect '"$SANDBOX_NAME"'
  '
