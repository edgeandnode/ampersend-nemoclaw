#!/usr/bin/env bash
# ampersend sandbox init — sourced from ~/.bashrc inside OpenShell sandboxes.
# Ensures /sandbox/.local/bin is in PATH and ampersend CLI is installed.
# Uploaded by setup-nemoclaw-in-docker.sh; safe to re-source on every login.

export PATH="/sandbox/.local/bin:$PATH"

if ! command -v ampersend &>/dev/null; then
  echo "[ampersend] CLI not found — installing..."
  if npm install -g @ampersend_ai/ampersend-sdk@0.0.16 \
       --prefix /sandbox/.local --ignore-scripts >/dev/null 2>&1 \
     && chmod +x /sandbox/.local/bin/ampersend 2>/dev/null; then
    echo "[ampersend] CLI installed ($(ampersend --version 2>/dev/null || echo '?'))."
  else
    echo "[ampersend] Auto-install failed. Install manually:"
    echo "  npm install -g @ampersend_ai/ampersend-sdk@0.0.16 --prefix /sandbox/.local --ignore-scripts"
  fi
fi
