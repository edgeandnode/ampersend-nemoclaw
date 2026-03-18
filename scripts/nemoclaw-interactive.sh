#!/usr/bin/env bash
# Spin up an interactive shell where you can run NemoClaw (setup, connect, openclaw tui).
# Uses Docker on your Mac to run Ubuntu; you get a bash prompt inside the container.
#
# Usage (from repo root):
#   ./scripts/nemoclaw-interactive.sh
#   # or with env from .env:
#   source .env && ./scripts/nemoclaw-interactive.sh
#
# Then inside the container:
#   nemoclaw setup          # first time only (creates sandbox; may prompt for NVIDIA API key)
#   nemoclaw my-assistant connect
#   # inside sandbox:
#   export ONECLAW_VAULT_ID=... ONECLAW_AGENT_ID=... ONECLAW_API_KEY=...
#   openclaw 1claw status
#   openclaw tui

set -e
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
SANDBOX_NAME="${SANDBOX_NAME:-my-assistant}"

if ! command -v docker &>/dev/null; then
  echo "Docker is required. Install Docker Desktop and try again."
  exit 1
fi

# Load .env if present
if [[ -f "$REPO_ROOT/.env" ]]; then
  set -a
  source "$REPO_ROOT/.env"
  set +a
fi

echo "=============================================="
echo "  Interactive NemoClaw (Ubuntu in Docker)"
echo "=============================================="
echo "  Repo:      $REPO_ROOT -> /workspace/1claw-nemoclaw"
echo "  Sandbox:   $SANDBOX_NAME"
echo ""
echo "  First time: run  nemoclaw onboard   (or nemoclaw setup; prompts for NVIDIA API key)"
echo "  Then:       run  nemoclaw $SANDBOX_NAME connect"
echo "  In sandbox: run  openclaw 1claw status   or   openclaw tui"
echo ""
echo "  If gateway fails: on your Mac run  nemoclaw setup-spark  (or in Docker Desktop"
echo "  add  \"default-cgroupns-mode\": \"host\"  to daemon.json and restart Docker)."
echo "=============================================="
echo ""

# Remove any stale container with the same name
docker rm -f 1claw-interactive 2>/dev/null || true

# OpenShell gateway needs host cgroup namespace (k3s inside Docker)
docker run --rm -it \
  --name 1claw-interactive \
  --cgroupns=host \
  -v "/var/run/docker.sock:/var/run/docker.sock" \
  -v "$REPO_ROOT:/workspace/1claw-nemoclaw:ro" \
  -e "SANDBOX_NAME=$SANDBOX_NAME" \
  -e "ONECLAW_VAULT_ID=${ONECLAW_VAULT_ID:-}" \
  -e "ONECLAW_AGENT_ID=${ONECLAW_AGENT_ID:-}" \
  -e "ONECLAW_API_KEY=${ONECLAW_API_KEY:-}" \
  -e "NVIDIA_API_KEY=${NVIDIA_API_KEY:-}" \
  -w /workspace \
  ubuntu:24.04 \
  bash -c '
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -qq && apt-get install -y -qq curl git ca-certificates docker.io > /dev/null

    curl -LsSf https://astral.sh/uv/install.sh | sh
    export PATH="$HOME/.local/bin:$PATH"
    uv tool install -U openshell

    curl -fsSL https://deb.nodesource.com/setup_20.x | bash - > /dev/null 2>&1
    apt-get install -y -qq nodejs > /dev/null

    if [[ ! -d /workspace/NemoClaw ]]; then
      git clone --depth 1 https://github.com/NVIDIA/NemoClaw.git /workspace/NemoClaw 2>/dev/null || true
    fi
    if [[ -d /workspace/NemoClaw && -f /workspace/NemoClaw/install.sh ]]; then
      cd /workspace/NemoClaw
      ./install.sh 2>/dev/null || true
      cd /workspace
    fi

    # Gateway runs on the host (Docker socket). From inside this container, point CLI at the host.
    export OPENSHELL_GATEWAY_ENDPOINT=https://host.docker.internal:8080
    openshell gateway add https://host.docker.internal:8080 --local 2>/dev/null || true

    echo ""
    echo "Ready. Gateway URL set to host (https://host.docker.internal:8080)."
    echo "  List sandboxes:  openshell sandbox list"
    echo "  Connect:         nemoclaw connect '"$SANDBOX_NAME"'   (or  nemoclaw '"$SANDBOX_NAME"' connect)"
    echo ""
    exec bash
  '
