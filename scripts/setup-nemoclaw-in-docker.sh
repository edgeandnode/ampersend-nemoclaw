#!/usr/bin/env bash
# Run Path 1 (README) inside Docker in one go: install, start gateway (plaintext to avoid TLS cert issues), create sandbox.
# Requires: Docker, and NVIDIA_API_KEY in .env (or env).
# After this, connect with: openshell sandbox connect my-assistant

set -e
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
SANDBOX_NAME="${SANDBOX_NAME:-my-assistant}"
MIN_OPENSHELL_VERSION="0.0.20"

if ! command -v docker &>/dev/null; then
  echo "Docker is required."
  exit 1
fi

if [[ -f "$REPO_ROOT/.env" ]]; then
  set -a
  source "$REPO_ROOT/.env"
  set +a
fi

if [[ -z "$NVIDIA_API_KEY" ]]; then
  echo "Add NVIDIA_API_KEY to .env (or export it), then re-run."
  echo "Get a key at https://build.nvidia.com/settings/api-keys"
  exit 1
fi

# Check Docker disk space — the OpenClaw image is ~1.5 GB and setup needs headroom.
DOCKER_DATA_USAGE=$(docker system df --format '{{.Size}}' 2>/dev/null | head -1)
DOCKER_DISK_FREE=$(docker system info --format '{{json .}}' 2>/dev/null | python3 -c '
import sys, json
try:
    info = json.load(sys.stdin)
    total = info.get("MemTotal", 0)
except: pass
' 2>/dev/null || true)

DOCKER_RECLAIMABLE=$(docker system df --format '{{.Reclaimable}}' 2>/dev/null | head -4 | paste -sd+ - | bc 2>/dev/null || echo "0")
IMAGE_SIZE=$(docker system df --format '{{.Size}}' 2>/dev/null | head -1)
echo "Checking Docker disk..."
echo "  Images: $IMAGE_SIZE"

RECLAIMABLE_BYTES=$(docker system df -v --format '{{.Reclaimable}}' 2>/dev/null | head -1 || echo "0")
TOTAL_RECLAIMABLE=$(docker system df --format '{{.Reclaimable}}' 2>/dev/null | tr '\n' ', ')
echo "  Reclaimable: $TOTAL_RECLAIMABLE"

# Warn if Docker is using a lot of space and offer to prune
DISK_USAGE_PCT=$(docker system info --format '{{json .DriverStatus}}' 2>/dev/null | \
  python3 -c 'import sys,json; ds=json.load(sys.stdin); pct=[v for k,v in ds if "percentage" in k.lower()]; print(pct[0].rstrip("%") if pct else "0")' 2>/dev/null || echo "0")
if [[ "${DISK_USAGE_PCT%%.*}" -ge 80 ]] 2>/dev/null; then
  echo ""
  echo "  WARNING: Docker disk usage is at ${DISK_USAGE_PCT}%."
  echo "  The OpenClaw sandbox image is ~1.5 GB. If disk is too full, Kubernetes"
  echo "  will garbage-collect images in a loop and the sandbox will never start."
  echo ""
  echo "  Run 'docker system prune -a --volumes -f' to free space, then re-run."
  echo "  (This removes unused images, containers, volumes, and build cache.)"
  echo ""
  exit 1
fi

echo "=============================================="
echo "  ampersend × NemoClaw in Docker (one-shot)"
echo "=============================================="
echo "  Sandbox name: $SANDBOX_NAME"
echo "  Repo:         $REPO_ROOT"
echo ""

docker run --rm \
  --cgroupns=host \
  -v "/var/run/docker.sock:/var/run/docker.sock" \
  -v "$REPO_ROOT:/workspace/ampersend-nemoclaw:ro" \
  -e "SANDBOX_NAME=$SANDBOX_NAME" \
  -e "NVIDIA_API_KEY=$NVIDIA_API_KEY" \
  -e "AMPERSEND_API_URL=${AMPERSEND_API_URL:-}" \
  -e "AMPERSEND_NETWORK=${AMPERSEND_NETWORK:-}" \
  -w /workspace \
  ubuntu:24.04 \
  bash -c '
    set -e
    export DEBIAN_FRONTEND=noninteractive
    echo "[1/7] Installing system deps..."
    apt-get update -qq && apt-get install -y -qq curl git ca-certificates docker.io > /dev/null

    echo "[2/7] Installing OpenShell and Node..."
    curl -LsSf https://astral.sh/uv/install.sh | sh
    export PATH="$HOME/.local/bin:$PATH"
    uv tool install -U openshell
    curl -fsSL https://deb.nodesource.com/setup_20.x | bash - > /dev/null 2>&1
    apt-get install -y -qq nodejs > /dev/null

    echo "[3/7] Installing NemoClaw..."
    if [[ ! -d /workspace/NemoClaw ]]; then
      git clone --depth 1 https://github.com/NVIDIA/NemoClaw.git /workspace/NemoClaw 2>/dev/null || true
    fi
    if [[ -d /workspace/NemoClaw && -f /workspace/NemoClaw/install.sh ]]; then
      cd /workspace/NemoClaw
      ./install.sh 2>/dev/null || true
      cd /workspace
    fi

    echo "[4/7] Saving NemoClaw credentials and registering gateway..."
    mkdir -p /root/.nemoclaw
    echo "{\"NVIDIA_API_KEY\":\"$NVIDIA_API_KEY\"}" > /root/.nemoclaw/credentials.json
    chmod 600 /root/.nemoclaw/credentials.json 2>/dev/null || true

    echo "  Registering gateway at host.docker.internal:8080 (up to 90s)..."
    GATEWAY_OK=
    for i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18; do
      if openshell gateway add http://host.docker.internal:8080 --local 2>/dev/null; then
        GATEWAY_OK=1
        echo "  Gateway registered."
        break
      fi
      sleep 5
    done
    if [[ -z "$GATEWAY_OK" ]]; then
      echo "  ERROR: Gateway not reachable. On your Mac run first:"
      echo "    openshell gateway start --plaintext"
      echo "  Then run: npm run setup:docker"
      exit 1
    fi

    echo "[5/7] Creating sandbox $SANDBOX_NAME (from openclaw community image)..."
    if openshell sandbox list 2>/dev/null | grep -q "$SANDBOX_NAME"; then
      echo "  Sandbox $SANDBOX_NAME already exists."
    else
      # --no-tty prevents the create command from opening an interactive shell
      openshell sandbox create --name "$SANDBOX_NAME" --from openclaw --no-tty -- exit
      openshell policy set --policy /workspace/ampersend-nemoclaw/config/ampersend-openshell-policy.yaml "$SANDBOX_NAME" 2>/dev/null || true
    fi

    echo "[6/7] Installing ampersend CLI and uploading plugin..."
    # The sandbox runs as non-root user "sandbox", so npm install -g to /usr/lib fails.
    # Install to /sandbox/.local instead, and --ignore-scripts avoids node-gyp failures
    # (nodejs.org is blocked by the sandbox network policy; JS fallbacks work fine).
    INSTALL_CMD="npm install -g @ampersend_ai/ampersend-sdk@0.0.16 --prefix /sandbox/.local --ignore-scripts 2>&1 && chmod +x /sandbox/.local/bin/ampersend 2>/dev/null"
    printf "%s; exit\n" "$INSTALL_CMD" | openshell sandbox connect "$SANDBOX_NAME" 2>/dev/null || true

    # Upload the init script that adds PATH and auto-installs on future logins.
    # "upload" copies into a directory, so upload to /sandbox/ then rename.
    openshell sandbox upload "$SANDBOX_NAME" /workspace/ampersend-nemoclaw/config/ampersend-sandbox-init.sh /sandbox/ 2>/dev/null || true
    printf "mv /sandbox/ampersend-sandbox-init.sh /sandbox/.ampersend-init.sh 2>/dev/null; chmod +x /sandbox/.ampersend-init.sh 2>/dev/null; grep -q ampersend-init.sh ~/.bashrc 2>/dev/null || echo \". /sandbox/.ampersend-init.sh\" >> ~/.bashrc; exit\n" \
      | openshell sandbox connect "$SANDBOX_NAME" 2>/dev/null || true
    echo "  ampersend CLI installed and PATH configured."

    if [[ -d /workspace/ampersend-nemoclaw/config/ampersend-plugin ]]; then
      openshell sandbox upload "$SANDBOX_NAME" /workspace/ampersend-nemoclaw/config/ampersend-plugin /sandbox/ampersend-plugin 2>/dev/null || true
      printf "openclaw plugins install /sandbox/ampersend-plugin 2>/dev/null; exit\n" | openshell sandbox connect "$SANDBOX_NAME" 2>/dev/null || true
      echo "  ampersend plugin uploaded and installed."
    else
      echo "  (config/ampersend-plugin not found; skip plugin install)"
    fi

    echo "[7/7] Installing OpenClaw skills (from config/skills-to-install.txt)..."
    SKILLS_FILE="/workspace/ampersend-nemoclaw/config/skills-to-install.txt"
    if [[ -f "$SKILLS_FILE" ]]; then
      SKILL_CMDS=""
      while IFS= read -r line; do
        line="${line%%#*}"
        line="$(echo "$line")"
        [[ -z "$line" ]] && continue
        SKILL_CMDS="${SKILL_CMDS}npx clawhub@latest install ${line} 2>/dev/null || true; "
      done < "$SKILLS_FILE"
      if [[ -n "$SKILL_CMDS" ]]; then
        printf "%s exit\n" "$SKILL_CMDS" | openshell sandbox connect "$SANDBOX_NAME" 2>/dev/null || true
        echo "  Skills from skills-to-install.txt queued."
      else
        echo "  (no skill names in file; add one per line)"
      fi
    else
      echo "  (config/skills-to-install.txt not found; skip skills)"
    fi

    echo ""
    echo "=============================================="
    echo "  Setup complete."
    echo ""
    echo "  Connect from your Mac:"
    echo "    openshell sandbox connect '"$SANDBOX_NAME"'"
    echo ""
    echo "  Inside the sandbox:"
    echo "    ampersend config status"
    echo "    ampersend setup start --name '"$SANDBOX_NAME"'"
    echo "    openclaw ampersend status"
    echo "=============================================="
  '

echo ""
echo "Done. Connect with:  openshell sandbox connect $SANDBOX_NAME"
