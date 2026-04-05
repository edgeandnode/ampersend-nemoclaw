#!/usr/bin/env bash
# Run the NemoClaw ampersend blueprint in dry-run mode (resolve + plan, no sandbox apply).

set -e
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
BLUEPRINT="$REPO_ROOT/config/nemoclaw-ampersend-blueprint.py"
SANDBOX_NAME="${SANDBOX_NAME:-ampersend-test-sandbox}"

echo "→ Testing NemoClaw blueprint (resolve + plan, --skip-apply)"
echo "  Blueprint: $BLUEPRINT"
echo "  Sandbox name: $SANDBOX_NAME"
echo ""

if [[ ! -f "$BLUEPRINT" ]]; then
  echo "ERROR: Blueprint not found."
  exit 1
fi

# Use venv if needed (avoids externally-managed-environment on macOS/Homebrew)
VENV_DIR="$REPO_ROOT/.venv"

# Detect stale venv (e.g. repo was moved/renamed and shebangs point to old path)
if [[ -d "$VENV_DIR" ]] && ! "$VENV_DIR/bin/python" --version &>/dev/null; then
  echo "Removing stale venv (interpreter not found — repo may have moved)..."
  rm -rf "$VENV_DIR"
fi

if ! python3 -c "import httpx, typer, yaml, rich" 2>/dev/null; then
  echo "Creating venv and installing Python deps..."
  python3 -m venv "$VENV_DIR"
  "$VENV_DIR/bin/pip" install -r "$REPO_ROOT/requirements.txt" -q
fi
if [[ -x "$VENV_DIR/bin/python" ]] && "$VENV_DIR/bin/python" -c "import httpx, typer, yaml, rich" 2>/dev/null; then
  PYTHON="$VENV_DIR/bin/python"
else
  PYTHON="python3"
fi

# Run blueprint with --skip-apply so we don't need OpenShell
"$PYTHON" "$BLUEPRINT" \
  --sandbox "$SANDBOX_NAME" \
  --skip-apply

echo ""
echo "Blueprint test (resolve + plan) finished. To apply to a real sandbox, run without --skip-apply:"
echo "  python3 $BLUEPRINT --sandbox $SANDBOX_NAME"
