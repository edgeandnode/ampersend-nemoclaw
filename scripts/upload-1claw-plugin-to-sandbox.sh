#!/usr/bin/env bash
# Upload the 1claw OpenClaw plugin bundle to a running sandbox so you can install it
# with: openclaw plugins install /sandbox/1claw-plugin
#
# Usage: ./scripts/upload-1claw-plugin-to-sandbox.sh [sandbox-name]
# Default sandbox name: my-assistant

set -e
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
SANDBOX_NAME="${1:-my-assistant}"
BUNDLE="$REPO_ROOT/config/1claw-plugin"

if [[ ! -d "$BUNDLE" ]]; then
  echo "Plugin bundle not found: $BUNDLE"
  exit 1
fi

if ! command -v openshell &>/dev/null; then
  echo "openshell CLI not found. Install it (e.g. uv tool install openshell) and ensure the gateway is running."
  exit 1
fi

echo "Uploading 1claw plugin bundle to sandbox '$SANDBOX_NAME' at /sandbox/1claw-plugin ..."
openshell sandbox upload "$SANDBOX_NAME" "$BUNDLE" /sandbox/1claw-plugin

echo ""
echo "Done. Connect to the sandbox and install the plugin:"
echo "  openshell sandbox connect $SANDBOX_NAME"
echo "  openclaw plugins install /sandbox/1claw-plugin"
echo ""
echo "Then set 1claw env vars and run: openclaw 1claw status"
