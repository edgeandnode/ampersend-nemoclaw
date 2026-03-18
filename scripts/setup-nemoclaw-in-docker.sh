#!/usr/bin/env bash
# Run Path 1 (README) inside Docker in one go: install, start gateway (plaintext to avoid TLS cert issues), create sandbox.
# Requires: Docker, and NVIDIA_API_KEY in .env (or env).
# After this, connect with: docker exec -it <sandbox-container> bash  (see docker ps)

set -e
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
SANDBOX_NAME="${SANDBOX_NAME:-my-assistant}"

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

echo "=============================================="
echo "  Path 1 in Docker (one-shot)"
echo "=============================================="
echo "  Sandbox name: $SANDBOX_NAME"
echo "  Repo:         $REPO_ROOT"
echo ""

docker run --rm \
  --cgroupns=host \
  -v "/var/run/docker.sock:/var/run/docker.sock" \
  -v "$REPO_ROOT:/workspace/1claw-nemoclaw:ro" \
  -e "SANDBOX_NAME=$SANDBOX_NAME" \
  -e "NVIDIA_API_KEY=$NVIDIA_API_KEY" \
  -e "ONECLAW_VAULT_ID=${ONECLAW_VAULT_ID:-}" \
  -e "ONECLAW_AGENT_ID=${ONECLAW_AGENT_ID:-}" \
  -e "ONECLAW_API_KEY=${ONECLAW_API_KEY:-}" \
  -e "ONECLAW_HUMAN_EMAIL=${ONECLAW_HUMAN_EMAIL:-}" \
  -e "ONECLAW_AGENT_NAME=${ONECLAW_AGENT_NAME:-}" \
  -w /workspace \
  ubuntu:24.04 \
  bash -c '
    set -e
    export DEBIAN_FRONTEND=noninteractive
    echo "[1/8] Installing system deps..."
    apt-get update -qq && apt-get install -y -qq curl git ca-certificates docker.io > /dev/null

    echo "[2/8] Installing OpenShell and Node..."
    curl -LsSf https://astral.sh/uv/install.sh | sh
    export PATH="$HOME/.local/bin:$PATH"
    uv tool install -U openshell
    curl -fsSL https://deb.nodesource.com/setup_20.x | bash - > /dev/null 2>&1
    apt-get install -y -qq nodejs > /dev/null

    echo "[3/8] Installing NemoClaw..."
    if [[ ! -d /workspace/NemoClaw ]]; then
      git clone --depth 1 https://github.com/NVIDIA/NemoClaw.git /workspace/NemoClaw 2>/dev/null || true
    fi
    if [[ -d /workspace/NemoClaw && -f /workspace/NemoClaw/install.sh ]]; then
      cd /workspace/NemoClaw
      ./install.sh 2>/dev/null || true
      cd /workspace
    fi

    echo "[4/8] Saving NemoClaw credentials and registering gateway..."
    mkdir -p /root/.nemoclaw
    echo "{\"NVIDIA_API_KEY\":\"$NVIDIA_API_KEY\"}" > /root/.nemoclaw/credentials.json
    chmod 600 /root/.nemoclaw/credentials.json 2>/dev/null || true

    # Use gateway on host. Start it on your Mac first: openshell gateway start --plaintext
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

    echo "[5/8] Creating sandbox $SANDBOX_NAME (from openclaw community image)..."
    if openshell sandbox list 2>/dev/null | grep -q "$SANDBOX_NAME"; then
      echo "  Sandbox $SANDBOX_NAME already exists."
    else
      openshell sandbox create --name "$SANDBOX_NAME" --from openclaw
      openshell policy set --policy /workspace/1claw-nemoclaw/config/1claw-openshell-policy.yaml "$SANDBOX_NAME" 2>/dev/null || true
    fi

    echo "[6/8] 1claw agent self-enroll (optional)..."
    if [[ -z "$ONECLAW_AGENT_ID" && -z "$ONECLAW_API_KEY" && -n "$ONECLAW_HUMAN_EMAIL" ]]; then
      ENROLL_NAME="${ONECLAW_AGENT_NAME:-$SANDBOX_NAME}"
      ENROLL_RESP=$(curl -s -X POST "https://api.1claw.xyz/v1/agents/enroll" \
        -H "Content-Type: application/json" \
        -d "{\"name\":\"$ENROLL_NAME\",\"human_email\":\"$ONECLAW_HUMAN_EMAIL\",\"description\":\"NemoClaw sandbox agent\"}" 2>/dev/null) || true
      if echo "$ENROLL_RESP" | grep -q "agent_id"; then
        ENROLL_AGENT_ID=$(echo "$ENROLL_RESP" | sed -n "s/.*\"agent_id\"[[:space:]]*:[[:space:]]*\"\([^\"]*\)\".*/\1/p" | head -1)
        echo "  Agent enrolled. Agent ID: $ENROLL_AGENT_ID"
        echo "  Check $ONECLAW_HUMAN_EMAIL for the API key. Then in the 1claw dashboard create a vault, add a policy for this agent, and set:"
        echo "    export ONECLAW_AGENT_ID=\"$ENROLL_AGENT_ID\""
        echo "    export ONECLAW_API_KEY=\"ocv_...\""
        echo "    export ONECLAW_VAULT_ID=\"<vault-id>\""
      else
        echo "  (Enroll failed or rate-limited; run \"openclaw 1claw enroll --email $ONECLAW_HUMAN_EMAIL\" inside the sandbox later.)"
      fi
    else
      echo "  (Set ONECLAW_HUMAN_EMAIL in .env to self-enroll when ONECLAW_AGENT_ID/ONECLAW_API_KEY are not set.)"
    fi

    echo "[7/8] Uploading and installing 1claw plugin..."
    if [[ -d /workspace/1claw-nemoclaw/config/1claw-plugin ]]; then
      openshell sandbox upload "$SANDBOX_NAME" /workspace/1claw-nemoclaw/config/1claw-plugin /sandbox/1claw-plugin 2>/dev/null || true
      printf "openclaw plugins install /sandbox/1claw-plugin 2>/dev/null; exit\n" | openshell sandbox connect "$SANDBOX_NAME" 2>/dev/null || true
      echo "  1claw plugin uploaded and installed."
    else
      echo "  (config/1claw-plugin not found; skip plugin install)"
    fi

    echo "[8/8] Installing OpenClaw skills (from config/skills-to-install.txt)..."
    SKILLS_FILE="/workspace/1claw-nemoclaw/config/skills-to-install.txt"
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
    echo "  Setup complete (gateway is plaintext — no TLS cert errors)."
    echo "  Connect:  docker ps  then  docker exec -it <sandbox-container-id> bash"
    echo "  Or:       npm run nemoclaw:interactive   then  nemoclaw '"$SANDBOX_NAME"' connect"
    echo "  From Mac: openshell gateway add http://127.0.0.1:8080 --local  then  openshell sandbox list"
    echo "=============================================="
  '

echo ""
echo "Run  docker ps  to find the sandbox container, then  docker exec -it <id> bash  to connect."
