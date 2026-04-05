# ampersend × OpenShell / NemoClaw

Use [ampersend](https://github.com/edgeandnode/ampersend-sdk) for agent payments inside [NemoClaw](https://github.com/NVIDIA/NemoClaw) sandboxes. This repo has the config (policy, plugin, blueprint) and two ways to use it: **run NemoClaw in Docker** and **connect from your Mac**.

ampersend enables autonomous agent payments using smart account wallets and the [x402 protocol](https://github.com/coinbase/x402). Agents can make payments within user-defined spending limits without requiring human approval for each transaction.

---

## Quick start

### Prerequisites

* **Docker Desktop** running on your Mac (with at least **5 GB free disk** — see Troubleshooting)
* **NVIDIA API key** — get one at <https://build.nvidia.com/settings/api-keys>
* **openshell >= 0.0.20** — install with `uv tool install -U openshell` (older versions cause sandbox crashes)

### 1. Configure

```bash
git clone https://github.com/edgeandnode/ampersend-nemoclaw.git
cd ampersend-nemoclaw
npm install
cp .env.example .env   # then edit .env
```

Set in `.env`:

| Variable           | Required | Description                         |
| ------------------ | -------- | ----------------------------------- |
| NVIDIA\_API\_KEY   | Yes      | NVIDIA API key for NemoClaw         |
| AMPERSEND\_API\_URL | Optional | Override ampersend API URL          |
| AMPERSEND\_NETWORK | Optional | Network: `base` or `base-sepolia`   |

### 2. Start the gateway

On your Mac:

```bash
openshell gateway start --plaintext
```

### 3. Run setup

```bash
npm run setup:docker
```

This single command:

* Installs OpenShell, Node.js, and NemoClaw in a temporary Docker container
* Registers the gateway and creates a sandbox (`my-assistant`)
* Applies the ampersend OpenShell policy
* Installs the ampersend CLI (`@ampersend_ai/ampersend-sdk`)
* Uploads and installs the ampersend OpenClaw plugin
* Installs any skills listed in `config/skills-to-install.txt`

### 4. Connect to the sandbox

```bash
npm run connect
```

Or via Docker:

```bash
docker ps
docker exec -it <sandbox-container-id> bash
```

### 5. Set up ampersend

Inside the sandbox:

```bash
# Two-step setup: generates a key, you approve in a browser
ampersend setup start --name "my-assistant"
# Returns: {"ok": true, "data": {"token": "...", "user_approve_url": "https://...", "agentKeyAddress": "0x..."}}

# Show the user_approve_url to the human so they can approve in their browser.

# Poll for approval and activate
ampersend setup finish
# Returns: {"ok": true, "data": {"agentKeyAddress": "0x...", "agentAccount": "0x...", "status": "ready"}}

# Verify
ampersend config status
```

Or via the OpenClaw plugin:

```bash
openclaw ampersend setup --name "my-assistant"
openclaw ampersend status
```

### 6. Make payments

```bash
# GET request with automatic x402 payment
ampersend fetch <url>

# POST with headers and body
ampersend fetch -X POST -H "Content-Type: application/json" -d '{"key":"value"}' <url>

# Check payment requirements without paying
ampersend fetch --inspect <url>
```

All commands return JSON — check the `ok` field. For `fetch`, successful responses include `data.status`, `data.body`, and `data.payment` (when a payment was made).

### 7. Add x402 payment endpoints to the network policy

The OpenShell sandbox blocks all outbound traffic by default. The included policy (`config/ampersend-openshell-policy.yaml`) already allows `api.ampersend.ai` (for setup/auth), Base RPC (for on-chain signing), and `httpay.xyz` (as a sample x402 server). **If your agent needs to pay a different x402-enabled server, you must add it to the policy.**

Open `config/ampersend-openshell-policy.yaml` and add an entry under `network_policies`. For example, to allow `api.example.com`:

```yaml
  my_x402_server:
    name: my-x402-server
    endpoints:
      - host: api.example.com
        port: 443
        protocol: rest
        tls: terminate
        enforcement: enforce
        access: read-write
    binaries:
      - path: /usr/bin/node
      - path: /usr/bin/npx
      - path: /sandbox/.local/bin/**
```

Or add the host to the existing `x402_endpoints` block:

```yaml
  x402_endpoints:
    name: x402-payment-endpoints
    endpoints:
      - host: httpay.xyz
        port: 443
        protocol: rest
        tls: terminate
        enforcement: enforce
        access: read-write
      - host: api.example.com        # ← add your host here
        port: 443
        protocol: rest
        tls: terminate
        enforcement: enforce
        access: read-write
    binaries:
      - path: /usr/bin/node
      - path: /usr/bin/npx
      - path: /sandbox/.local/bin/**
```

Then hot-reload the policy on the live sandbox (no restart needed):

```bash
openshell policy set my-assistant --policy config/ampersend-openshell-policy.yaml
```

> **Note:** The `filesystem_policy.read_only` list must include all paths from the base image (e.g. `/app`, `/var/log` for OpenClaw). If you see an error like `"path '/app' cannot be removed on a live sandbox"`, add the missing path to the `read_only` list and retry.

---

## Path 1: Run NemoClaw in Docker

You run a Linux container on your Mac; inside it you use a gateway and create a sandbox. Do this first.

### 1.0 Start the gateway on your Mac (one-time)

So the container can reach it, start a **plaintext** gateway on your Mac:

```bash
openshell gateway start --plaintext
```

(If you use `npm run setup:docker`, do this first so the script can register the gateway from inside the container.)

### 1.1 Start the container

On your Mac, in this repo:

```bash
cd ampersend-nemoclaw
npm install
npm run nemoclaw:interactive
```

Wait until you see a prompt like `root@xxxxx:/workspace#`.

### 1.2 Tell the CLI where the gateway is

Inside the container, run once:

```bash
openshell gateway add https://host.docker.internal:8080 --local
```

### 1.3 Create the sandbox (first time only)

Inside the container:

```bash
nemoclaw onboard
```

Paste your **NVIDIA API key** when asked (create one at https://build.nvidia.com/settings/api-keys). If you see "Gateway failed to start", see **Troubleshooting** below.

### 1.4 Connect to the sandbox

Inside the container:

```bash
openshell sandbox list
nemoclaw my-assistant connect
```

If no sandbox exists, create it and apply the ampersend policy:

```bash
openshell sandbox create --name my-assistant --from openclaw
openshell policy set --policy /workspace/ampersend-nemoclaw/config/ampersend-openshell-policy.yaml my-assistant
nemoclaw my-assistant connect
```

### 1.5 Use ampersend in the sandbox

You're now inside the sandbox. If you used `npm run setup:docker`, the ampersend CLI is already installed and in PATH. Otherwise install it manually:

```bash
# The sandbox runs as non-root, so install to a local prefix.
# --ignore-scripts skips native builds (nodejs.org is blocked by the network policy).
npm install -g @ampersend_ai/ampersend-sdk@0.0.16 --prefix /sandbox/.local --ignore-scripts
chmod +x /sandbox/.local/bin/ampersend
export PATH="/sandbox/.local/bin:$PATH"
```

Then configure:

```bash
ampersend setup start --name "my-assistant"
# Approve in browser, then:
ampersend setup finish
ampersend config status
```

Or use via OpenClaw:

```bash
openclaw ampersend status
openclaw ampersend fetch <x402-enabled-url>
openclaw tui
```

### 1.6 If `openclaw ampersend` says "unknown command"

The openclaw community image does not include the ampersend plugin by default. **If you used `npm run setup:docker`**, the plugin is uploaded and installed automatically, so you can skip this.

If you created the sandbox manually:

**From your Mac** (gateway and sandbox already running):

```bash
npm run plugin:upload
```

**Then connect to the sandbox** and install the plugin:

```bash
openshell sandbox connect my-assistant
# Inside the sandbox:
openclaw plugins install /sandbox/ampersend-plugin
openclaw ampersend status
```

### 1.7 Auto-install OpenClaw skills

When you run `npm run setup:docker`, the script installs skills from `config/skills-to-install.txt`. By default this includes `ampersend`. Edit the file to add or remove skills.

---

## Path 2: Connect from your Mac to the Docker sandbox

After you've run Path 1, the gateway and sandbox run in Docker on your Mac.

### Why two Docker containers?

| Container | Image | What it is |
|-----------|--------|------------|
| **openshell-cluster-openshell** | `nvidia/openshell/cluster:dev` | The **OpenShell gateway**. Stays running. |
| *(random name)* | `ubuntu:24.04` | The **setup runner**. Exits when done. |

### 2.1 Easiest: use Docker (no install)

```bash
docker ps
docker exec -it <container-name-or-id> bash
```

You're inside the same sandbox. Run `ampersend config status` or `openclaw ampersend status`.

### 2.2 Optional: NemoClaw CLI on your Mac

Install the CLI from [NVIDIA/NemoClaw](https://github.com/NVIDIA/NemoClaw), then `nemoclaw my-assistant connect`.

---

## ampersend setup (agent payments)

ampersend lets agents make payments via smart account wallets with automatic x402 payment handling. It is bundled as a skill in the OpenClaw plugin.

### Install the CLI (inside the sandbox)

If you used `npm run setup:docker`, the CLI is already installed. Otherwise:

```bash
npm install -g @ampersend_ai/ampersend-sdk@0.0.16 --prefix /sandbox/.local --ignore-scripts
chmod +x /sandbox/.local/bin/ampersend
export PATH="/sandbox/.local/bin:$PATH"
```

### Configure

```bash
# 1. Two-step setup: generates a key, requests approval
ampersend setup start --name "my-assistant"
# Returns: {"ok": true, "data": {"token": "...", "user_approve_url": "https://...", "agentKeyAddress": "0x..."}}

# Show the user_approve_url to the human. They approve in their browser.

# 2. Poll for approval and activate
ampersend setup finish
# Returns: {"ok": true, "data": {"agentKeyAddress": "0x...", "agentAccount": "0x...", "status": "ready"}}

# 3. Verify
ampersend config status
# Returns: {"ok": true, "data": {"status": "ready", ...}}
```

### Usage

```bash
# GET request with automatic x402 payment
ampersend fetch <url>

# POST with headers and body
ampersend fetch -X POST -H "Content-Type: application/json" -d '{"key":"value"}' <url>

# Check payment requirements without paying
ampersend fetch --inspect <url>
```

### Manual configuration

If you already have an agent key and account address:

```bash
ampersend config set "0xagentKey:::0xagentAccount"
```

---

## Troubleshooting

- **Sandbox stuck in "Provisioning" or CrashLoopBackOff with gRPC "Unimplemented"**
  This is an openshell version mismatch. The CLI must be >= 0.0.20 to work with the current gateway image. Check with `openshell --version`. Upgrade: `uv tool install -U openshell` (then ensure `~/.local/bin` is in your PATH). After upgrading, destroy and restart: `openshell gateway destroy && openshell gateway start --plaintext`.

- **Docker disk full / sandbox image keeps getting garbage-collected**
  If Kubernetes disk usage exceeds 85%, it garbage-collects the 1.4 GB OpenClaw image in a loop. Free space: `docker system prune -a --volumes -f` (removes unused images, build cache, volumes). The setup script checks for this and warns you.

- **"Gateway failed to start"**
  Exit the container. On your Mac: Docker Desktop -> Settings -> Docker Engine. Add `"default-cgroupns-mode": "host"` to the JSON. Apply & Restart.

- **"Connection refused" when running `openshell sandbox list` inside the container**
  You skipped gateway registration. Run: `openshell gateway add https://host.docker.internal:8080 --local`, then try again.

- **"invalid peer certificate: BadSignature"**
  Use `npm run setup:docker` or start a plaintext gateway: `openshell gateway start --plaintext`.

- **Intel Mac: `openshell` won't install natively**
  No `macosx_x86_64` wheel exists. Use `npm run gateway:start` — it detects this and runs the gateway inside Docker.

- **Docker keychain errors on locked sessions**
  If Docker fails with `docker-credential-desktop: signal: killed`, open `~/.docker/config.json` and change `"credsStore": "desktop"` to `"credsStore": ""`.

- **`ampersend` command not found inside sandbox**
  If you used `npm run setup:docker`, reconnect — the CLI auto-installs on login. Otherwise install manually: `npm install -g @ampersend_ai/ampersend-sdk@0.0.16 --prefix /sandbox/.local --ignore-scripts && chmod +x /sandbox/.local/bin/ampersend && export PATH="/sandbox/.local/bin:$PATH"`

- **`npm install -g` EACCES / permission denied inside sandbox**
  The sandbox runs as non-root user `sandbox`. Use `--prefix /sandbox/.local` instead of global install. Add `--ignore-scripts` to skip native builds (the network policy blocks `nodejs.org`).

- **Stale Python venv (`bad interpreter` error in test-blueprint.sh)**
  If the repo was moved or renamed, delete the old venv: `rm -rf .venv` and re-run `npm test`.

---

## What's in this repo

| Path | Description |
|------|-------------|
| **config/ampersend-openshell-policy.yaml** | OpenShell policy (ampersend, NVIDIA, npm, GitHub). |
| **config/openclaw-ampersend-plugin.ts** | OpenClaw plugin: `openclaw ampersend status`, `setup`, `fetch`, `inspect`, etc. |
| **config/nemoclaw-ampersend-blueprint.py** | Blueprint to apply ampersend policy to a sandbox. |
| **config/ampersend-plugin/** | Plugin bundle uploaded into sandboxes. |
| **config/ampersend-sandbox-init.sh** | Shell init sourced on login; auto-installs ampersend CLI if missing. |
| **config/skills-to-install.txt** | Skills to auto-install during setup. |

---

## How to test

**Without the sandbox (local):** From the repo root, run `npm test` (policy validation + blueprint dry-run + plugin status).

**Inside the sandbox (full flow):** (1) On your Mac: `openshell gateway start --plaintext`, then `npm run setup:docker`. (2) Connect: `docker exec -it <sandbox-container> bash`. (3) In the sandbox: `ampersend config status`, `ampersend fetch <url>`, or `openclaw ampersend status`. See [Testing guide](scripts/README-TESTING.md).

---

## Other commands

| Command | Description |
|--------|-------------|
| `npm run setup:docker` | One-shot: install, gateway, create sandbox, apply ampersend policy, install CLI + plugin + skills. |
| `npm run plugin:upload` | Upload the ampersend plugin bundle to the sandbox. |
| `npm run nemoclaw:interactive` | Start an interactive Docker shell for manual NemoClaw steps. |
| `npm test` | Run tests (policy, blueprint, plugin). |
| `npm run test:ampersend` | Test ampersend CLI config and API reachability. |

---

## Links

- [ampersend SDK](https://github.com/edgeandnode/ampersend-sdk) · [ampersend CLI reference](https://www.ampersend.ai/skill.md) · [x402 Protocol](https://github.com/coinbase/x402) · [OpenShell](https://docs.nvidia.com/openshell/latest/) · [NemoClaw](https://docs.nvidia.com/nemoclaw/latest/get-started/quickstart.html) · [Testing guide](scripts/README-TESTING.md)
