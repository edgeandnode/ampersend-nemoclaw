#!/usr/bin/env bash
# Clone (or use cached) the 1claw OpenClaw plugin, install deps, and upload to a sandbox.
# Then install it with: openclaw plugins install /sandbox/1claw-plugin
#
# Usage: ./scripts/upload-1claw-plugin-to-sandbox.sh [sandbox-name]
# Default sandbox name: my-assistant

set -e
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
SANDBOX_NAME="${1:-my-assistant}"
PLUGIN_DIR="$REPO_ROOT/.cache/1claw-openclaw-plugin"
PLUGIN_REPO="https://github.com/1clawAI/1claw-openclaw-plugin.git"

# Clone if not cached
if [[ ! -d "$PLUGIN_DIR" ]]; then
  echo "Cloning $PLUGIN_REPO ..."
  mkdir -p "$(dirname "$PLUGIN_DIR")"
  git clone --depth 1 "$PLUGIN_REPO" "$PLUGIN_DIR"
else
  echo "Using cached plugin at $PLUGIN_DIR"
  echo "  (To update: rm -rf $PLUGIN_DIR and re-run)"
fi

# Install deps (sandbox has no npm registry access)
cd "$PLUGIN_DIR"
if [[ ! -d node_modules ]]; then
  echo "Installing plugin dependencies..."
  npm install --production
fi

# Remove .gitignore so openshell upload includes node_modules
rm -f .gitignore

cd "$REPO_ROOT"

# Upload — works natively or falls back to Docker
if command -v openshell &>/dev/null; then
  echo "Uploading 1claw plugin to sandbox '$SANDBOX_NAME' at /sandbox/1claw-plugin ..."
  openshell sandbox upload "$SANDBOX_NAME" "$PLUGIN_DIR" /sandbox/1claw-plugin
else
  echo "openshell CLI not found. Uploading via Docker..."
  if ! docker ps --format '{{.Names}}' 2>/dev/null | grep -q "openshell-cluster-openshell"; then
    echo "ERROR: OpenShell gateway is not running. Start it first: npm run gateway:start"
    exit 1
  fi
  docker run --rm \
    --cgroupns=host \
    -v "/var/run/docker.sock:/var/run/docker.sock" \
    -v "$PLUGIN_DIR:/workspace/1claw-plugin:ro" \
    ubuntu:24.04 \
    bash -c '
      export DEBIAN_FRONTEND=noninteractive
      apt-get update -qq && apt-get install -y -qq curl ca-certificates docker.io > /dev/null
      curl -LsSf https://astral.sh/uv/install.sh | sh 2>/dev/null
      export PATH="$HOME/.local/bin:$PATH"
      uv tool install -U openshell 2>/dev/null
      openshell gateway add http://host.docker.internal:8080 --local 2>/dev/null
      openshell sandbox upload "'"$SANDBOX_NAME"'" /workspace/1claw-plugin /sandbox/1claw-plugin
    '
fi

echo ""
echo "Done. Connect to the sandbox and install the plugin:"
echo "  npm run connect"
echo "  openclaw plugins install /sandbox/1claw-plugin"
echo ""
echo "Then set 1claw env vars and run: openclaw 1claw status"
