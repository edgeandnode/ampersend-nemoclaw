# 1claw × NemoClaw

Use [1claw](https://1claw.xyz) secrets management inside [NemoClaw](https://github.com/NVIDIA/NemoClaw) sandboxes running on Docker.

## Quick start

### Prerequisites

- **Docker Desktop** running on your Mac
- **NVIDIA API key** — get one at https://build.nvidia.com/settings/api-keys

### 1. Configure

```bash
git clone https://github.com/1clawAI/1claw-nemoclaw.git
cd 1claw-nemoclaw
npm install
cp .env.example .env   # then edit .env
```

Set in `.env`:

| Variable | Required | Description |
|----------|----------|-------------|
| `NVIDIA_API_KEY` | Yes | NVIDIA API key for NemoClaw |
| `ONECLAW_HUMAN_EMAIL` | Optional | Your email — auto-enrolls a 1claw agent during setup |
| `ONECLAW_AGENT_ID` | Optional | If you already have a 1claw agent |
| `ONECLAW_AGENT_API_KEY` | Optional | Your 1claw agent API key (`ocv_...`) |
| `ONECLAW_VAULT_ID` | Optional | Your 1claw vault ID |

### 2. Start the gateway

```bash
npm run gateway:start
```

This starts the OpenShell gateway in plaintext mode. On Intel Macs (no native `openshell` wheel), it runs inside Docker automatically.

### 3. Run setup

```bash
npm run setup:docker
```

This single command:
- Installs OpenShell, Node.js, and NemoClaw in a temporary Docker container
- Registers the gateway and creates a sandbox (`my-assistant`)
- Applies the 1claw OpenShell policy
- Self-enrolls a 1claw agent (if `ONECLAW_HUMAN_EMAIL` is set)
- Clones and installs the [1claw OpenClaw plugin](https://github.com/1clawAI/1claw-openclaw-plugin)
- Installs any skills listed in `config/skills-to-install.txt`

### 4. Connect to the sandbox

```bash
npm run connect
```

This connects to the `my-assistant` sandbox. Works on Intel Macs — runs `openshell sandbox connect` natively or via Docker.

### 5. Set 1claw credentials

Inside the sandbox:

```bash
export ONECLAW_AGENT_ID="your-agent-id"
export ONECLAW_AGENT_API_KEY="ocv_..."
export ONECLAW_VAULT_ID="your-vault-id"
openclaw 1claw status
```

**Don't have credentials yet?** Enroll from your Mac (or inside the sandbox):

```bash
curl -s -X POST "https://api.1claw.xyz/v1/agents/enroll" \
  -H "Content-Type: application/json" \
  -d '{"name":"my-assistant","human_email":"you@example.com","description":"OpenClaw agent"}'
```

Check your email for the API key, then create a vault and policy in the [1claw dashboard](https://1claw.xyz).

---

## OpenClaw TUI (optional)

The TUI is a chat interface for the AI agent — it is **not** a shell. Inside the sandbox:

```bash
# 1. Set up Anthropic API key (powers the AI agent)
openclaw agents add main --provider anthropic --api-key "$ANTHROPIC_API_KEY"

# 2. Start the OpenClaw gateway (separate from OpenShell)
openclaw gateway run --auth token --token mytoken --allow-unconfigured &
sleep 2

# 3. Launch the TUI
openclaw tui --token mytoken
```

The 1claw plugin registers TUI slash commands: `/oneclaw` (status), `/oneclaw-enroll`, `/oneclaw-list`, `/oneclaw-rotate`.

---

## Ampersend setup (agent payments)

[Ampersend](https://clawhub.ai/matiasedgeandnode/ampersend) lets agents make payments via smart account wallets with automatic [x402](https://www.x402.org/) payment handling. It is bundled as a skill in the 1claw plugin.

### Install the CLI (inside the sandbox)

```bash
npm install -g @ampersend_ai/ampersend-sdk@beta
```

### Configure

```bash
# 1. Initialize — generates a session key
ampersend config init
# Returns: {"ok": true, "data": {"sessionKeyAddress": "0x...", "status": "pending_agent"}}

# 2. Register the sessionKeyAddress in the Ampersend dashboard

# 3. Link your smart account
ampersend config set-agent <SMART_ACCOUNT_ADDRESS>

# 4. Verify
ampersend config status
# Returns: {"ok": true, "data": {"status": "ready", ...}}
```

### Usage

```bash
# GET request with automatic x402 payment
ampersend fetch <url>

# POST with headers and body
ampersend fetch -X POST -H "Content-Type: application/json" -d '{"key":"value"}' <url>
```

All commands return JSON — check the `ok` field. For `fetch`, successful responses include `data.status`, `data.body`, and `data.payment` (when a payment was made).

---

## Manual setup (alternative to quick start)

If you prefer to run each step manually instead of `npm run setup:docker`:

### Start an interactive container

```bash
npm run nemoclaw:interactive
```

### Inside the container

```bash
# Register the gateway
openshell gateway add https://host.docker.internal:8080 --local

# Create sandbox and apply policy
openshell sandbox create --name my-assistant --from openclaw
openshell policy set --policy /workspace/1claw-nemoclaw/config/1claw-openshell-policy.yaml my-assistant

# Connect
nemoclaw my-assistant connect
```

### Install the 1claw plugin manually

From your Mac (gateway and sandbox must be running):

```bash
npm run plugin:upload
```

Then inside the sandbox:

```bash
openclaw plugins install /sandbox/1claw-plugin
```

The upload script clones the [upstream plugin](https://github.com/1clawAI/1claw-openclaw-plugin), runs `npm install` (the sandbox has no npm registry access), and uploads with `node_modules` included.

### Auto-install OpenClaw skills

Add skill names (one per line) to `config/skills-to-install.txt`:

```
github
docker-essentials
ampersend
```

These are installed with `npx clawhub@latest install <name>` during `npm run setup:docker`.

---

## Architecture

```
┌─────────────────────────────────────────────────┐
│  Your Mac                                       │
│                                                 │
│  npm run gateway:start                          │
│       │                                         │
│       ▼                                         │
│  ┌──────────────────────────────────────────┐   │
│  │  openshell-cluster-openshell (Docker)    │   │
│  │  OpenShell gateway — port 8080           │   │
│  │                                          │   │
│  │  ┌────────────────────────────────────┐  │   │
│  │  │  my-assistant (k3s pod)            │  │   │
│  │  │  Sandbox with OpenClaw + 1claw     │  │   │
│  │  └────────────────────────────────────┘  │   │
│  └──────────────────────────────────────────┘   │
│                                                 │
│  npm run connect  ──────────────────────────┘   │
└─────────────────────────────────────────────────┘
```

Sandboxes are k3s pods **inside** the gateway container — they don't appear as separate containers in `docker ps`.

| Container name | What it is |
|----------------|------------|
| `openshell-cluster-openshell` | OpenShell gateway (stays running) |
| `1claw-setup` | Temporary setup runner (exits when done) |
| `1claw-interactive` | Interactive shell (for manual setup) |

---

## Commands

| Command | Description |
|---------|-------------|
| `npm run gateway:start` | Start the OpenShell plaintext gateway |
| `npm run setup:docker` | One-shot automated setup (requires `NVIDIA_API_KEY` in `.env`) |
| `npm run connect` | Connect to the sandbox from your Mac |
| `npm run plugin:upload` | Upload the 1claw plugin to the sandbox |
| `npm run nemoclaw:interactive` | Interactive Docker shell for manual steps |
| `npm test` | Run tests (policy, blueprint, plugin) |

---

## What's in this repo

| Path | Description |
|------|-------------|
| `config/1claw-openshell-policy.yaml` | OpenShell policy (1claw, NVIDIA, npm, GitHub) |
| `config/nemoclaw-1claw-blueprint.py` | Blueprint to apply 1claw policy to a sandbox |
| `config/skills-to-install.txt` | Skills to auto-install during setup |
| [1claw-openclaw-plugin](https://github.com/1clawAI/1claw-openclaw-plugin) | OpenClaw plugin (cloned at setup time) |

---

## Troubleshooting

**Intel Mac: `openshell` won't install natively**
No `macosx_x86_64` wheel exists. Use `npm run gateway:start` — it detects this and runs the gateway inside Docker.

**Docker keychain errors on locked sessions**
If Docker fails with `docker-credential-desktop: signal: killed`, open `~/.docker/config.json` and change `"credsStore": "desktop"` to `"credsStore": ""`.

**`openclaw tui` says "Missing gateway auth token"**
Start the OpenClaw gateway first: `openclaw gateway run --auth token --token mytoken --allow-unconfigured &`, then `openclaw tui --token mytoken`.

**"Gateway start blocked: set gateway.mode=local"**
Pass `--allow-unconfigured`: `openclaw gateway run --auth token --token mytoken --allow-unconfigured &`.

**"Gateway failed to start"**
In Docker Desktop: Settings > Docker Engine > add `"default-cgroupns-mode": "host"` to the JSON. Apply & Restart.

**"Connection refused" from `openshell sandbox list`**
Run `openshell gateway add https://host.docker.internal:8080 --local` first.

**"invalid peer certificate: BadSignature"**
Use `npm run setup:docker` or `npm run connect` — they handle certs automatically. Or start a plaintext gateway: `openshell gateway start --plaintext`.

---

## Links

[1claw](https://1claw.xyz) · [OpenShell docs](https://docs.nvidia.com/openshell/latest/) · [NemoClaw docs](https://docs.nvidia.com/nemoclaw/latest/get-started/quickstart.html) · [Testing guide](scripts/README-TESTING.md)
