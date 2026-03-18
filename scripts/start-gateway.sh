#!/usr/bin/env bash
# Start the OpenShell plaintext gateway.
# Uses the native openshell CLI if available, otherwise runs it in Docker.
# The gateway listens on port 8080 (plaintext, no TLS).

set -e

GATEWAY_CONTAINER_NAME="1claw-gateway"

# Check if gateway is already running
if docker ps --format '{{.Names}}' 2>/dev/null | grep -q "openshell-cluster-openshell"; then
  echo "Gateway is already running (openshell-cluster-openshell container found)."
  echo "To stop it: openshell gateway stop  (or docker stop openshell-cluster-openshell)"
  exit 0
fi

if command -v openshell &>/dev/null; then
  echo "Starting gateway using native openshell CLI..."
  # Destroy stale config if the container was removed but config remains
  openshell gateway destroy 2>/dev/null || true
  openshell gateway start --plaintext
  echo ""
  echo "Gateway started on port 8080 (plaintext)."
  echo "Stop with: openshell gateway stop"
else
  echo "openshell CLI not found natively (common on Intel Macs — no x86_64 wheel)."
  echo "Starting gateway via Docker..."

  if ! command -v docker &>/dev/null; then
    echo "ERROR: Docker is required. Install Docker Desktop and try again."
    exit 1
  fi

  # Remove stale wrapper container if present
  docker rm -f "$GATEWAY_CONTAINER_NAME" 2>/dev/null || true

  # The wrapper installs openshell and runs `openshell gateway start --plaintext`,
  # which spawns the actual gateway as a separate container (openshell-cluster-openshell).
  # The wrapper exits after that; the gateway container stays running.
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

      # Destroy stale gateway config if the container is gone but config remains.
      # "gateway start" would say "already exists, reusing" without actually starting.
      openshell gateway destroy 2>/dev/null || true

      echo "Starting OpenShell gateway (plaintext, port 8080)..."
      openshell gateway start --plaintext
    '

  echo ""
  echo "Gateway started on port 8080 (plaintext) via Docker."
  echo "Stop with: docker stop openshell-cluster-openshell"
fi
