# 1claw × OpenShell / NemoClaw

Use [1claw.xyz](https://1claw.xyz) for secrets inside [NemoClaw](https://github.com/NVIDIA/NemoClaw) sandboxes. This repo has the config (policy, plugin, blueprint) and two ways to use it: **run NemoClaw in Docker** and **connect from your Mac**.

---

## Path 1: Run NemoClaw in Docker

You run a Linux container on your Mac; inside it you use a gateway and create a sandbox. Do this first.

### 1.0 Start the gateway on your Mac (one-time)

So the container can reach it, start a **plaintext** gateway on your Mac:

```bash
npm run gateway:start
```

This runs `openshell gateway start --plaintext` if openshell is installed natively, or starts the gateway inside Docker if not (common on Intel Macs where no `macosx_x86_64` wheel is available). If you use `npm run setup:docker`, do this first so the script can register the gateway from inside the container.

### 1.1 Start the container

On your Mac, in this repo:

```bash
cd 1claw-nemoclaw
npm install
npm run nemoclaw:interactive
```

Wait until you see a prompt like `root@xxxxx:/workspace#`.

### 1.2 Tell the CLI where the gateway is

Inside the container, run once:

```bash
openshell gateway add https://host.docker.internal:8080 --local
```

(The gateway will run on your Mac’s Docker; this makes the CLI inside the container talk to it.)

### 1.3 Create the sandbox (first time only)

Inside the container:

```bash
nemoclaw onboard
```

Paste your **NVIDIA API key** when asked (create one at https://build.nvidia.com/settings/api-keys). The gateway starts on your Mac. If you see “Gateway failed to start”, see **Troubleshooting** below.

### 1.4 Connect to the sandbox (from inside the container)

Inside the container:

```bash
openshell sandbox list
nemoclaw my-assistant connect
```

If no sandbox exists, create it (openclaw community image) and apply the 1claw policy, then connect:

```bash
openshell sandbox create --name my-assistant --from openclaw
openshell policy set --policy /workspace/1claw-nemoclaw/config/1claw-openshell-policy.yaml my-assistant
nemoclaw my-assistant connect
```

### 1.5 Use 1claw in the sandbox

You’re now inside the sandbox.

**If you already have 1claw credentials** (vault, agent, API key), set them and run:

```bash
export ONECLAW_VAULT_ID="your-vault-id"
export ONECLAW_AGENT_ID="your-agent-id"
export ONECLAW_AGENT_API_KEY="ocv_..."
openclaw 1claw status
```

### 1.5a Start the OpenClaw TUI

The OpenClaw TUI is a chat interface for the AI agent — it is **not** a shell. The 1claw plugin registers TUI slash commands (`/oneclaw`, `/oneclaw-enroll`, `/oneclaw-list`).

**1. Configure the Anthropic API key** (required for the AI agent):

```bash
export ANTHROPIC_API_KEY="your-anthropic-api-key"
openclaw agents add main --provider anthropic --api-key "$ANTHROPIC_API_KEY"
```

**2. Start the OpenClaw gateway** (separate from the OpenShell gateway):

```bash
openclaw gateway run --auth token --token mytoken --allow-unconfigured &
sleep 2
```

**3. Launch the TUI:**

```bash
openclaw tui --token mytoken
```

- `--allow-unconfigured` is required because `gateway.mode` is not set in the sandbox's OpenClaw config.
- `--auth token --token mytoken` sets a shared token; the TUI uses the same token to connect.
- The gateway runs in the background (`&`); the TUI connects to it on `ws://127.0.0.1:18789`.
- To exit the TUI, press Ctrl+C or `q`.

**If you don’t have credentials yet (agent self-onboarding):** the agent can self-enroll with 1claw; the API key is emailed to you. Either:

- **During setup:** set `ONECLAW_HUMAN_EMAIL=you@example.com` in `.env` (leave `ONECLAW_AGENT_ID` and `ONECLAW_AGENT_API_KEY` empty) before running `npm run setup:docker`. The setup script will call the [enroll API](https://docs.1claw.xyz/docs/guides/agent-self-onboarding); check your email for the key, then create a vault and policy in the 1claw dashboard and set the three env vars above.

- **Inside the sandbox (curl):** run:
  ```bash
  curl -s -X POST "https://api.1claw.xyz/v1/agents/enroll" \
    -H "Content-Type: application/json" \
    -d ‘{"name":"my-assistant","human_email":"you@example.com","description":"OpenClaw agent"}’
  ```
  Check your email for the API key, create a vault and policy in the [1claw dashboard](https://1claw.xyz), then:
  ```bash
  export ONECLAW_AGENT_ID="..." ONECLAW_AGENT_API_KEY="ocv_..." ONECLAW_VAULT_ID="..."
  ```

- **In the TUI:** use the `/oneclaw-enroll you@example.com` slash command.

`openclaw tui` is the chat UI. This repo is mounted at `/workspace/1claw-nemoclaw`.

### 1.6 If `openclaw 1claw` says "unknown command"

The openclaw community image does not include the 1claw plugin by default. **If you used `npm run setup:docker`**, the plugin is uploaded and installed automatically during setup, so you can skip this.

If you created the sandbox manually (e.g. via Path 1 step 1.4) or need to reinstall/update the plugin:

**From your Mac** (gateway and sandbox already running):

```bash
npm run plugin:upload
# Or: ./scripts/upload-1claw-plugin-to-sandbox.sh my-assistant
```

**Then connect to the sandbox** and install the plugin:

```bash
npm run connect
# Inside the sandbox:
openclaw plugins install /sandbox/1claw-plugin
export ONECLAW_VAULT_ID="your-vault-id"
export ONECLAW_AGENT_ID="your-agent-id"
export ONECLAW_AGENT_API_KEY="ocv_..."
openclaw 1claw status
```

The plugin is the upstream [1claw-openclaw-plugin](https://github.com/1clawAI/1claw-openclaw-plugin). The upload script clones it, runs `npm install` (sandbox has no npm registry access), and uploads with `node_modules` included.

### 1.7 Auto-install OpenClaw skills

When you run `npm run setup:docker`, the script can install [OpenClaw skills](https://openclawforge.com/blog/openclaw-add-skills-complete-installation-configuration-guide/) (from ClawHub) into the sandbox. **Configure the list** in:

**`config/skills-to-install.txt`**

- One skill name per line (e.g. `github`, `docker-essentials`).
- Lines starting with `#` are ignored.
- If the file is missing or empty, the step is skipped.

Skills are installed with `npx clawhub@latest install <name>` inside the sandbox after the 1claw plugin is installed. Edit this file before running `npm run setup:docker` to add or remove skills.

---

## Path 2: Connect from your Mac to the Docker sandbox

After you’ve run Path 1, the gateway and sandbox run in Docker on your Mac. To get a shell in **that same sandbox** from your Mac, use one of these.

### Why two Docker containers?

When you run the setup you will see (at least) two containers in `docker ps`:

| Container | Image | What it is |
|-----------|--------|------------|
| **openshell-cluster-openshell** | `nvidia/openshell/cluster:dev` | The **OpenShell gateway**. Started by `npm run gateway:start` (or `openshell gateway start --plaintext`). It is the control plane: it runs the gateway API (port 8080), manages sandboxes, and applies policies. This one stays running. |
| **1claw-setup** | `ubuntu:24.04` | The **setup runner**. Created by `npm run setup:docker`. It installs OpenShell, NemoClaw, registers the gateway, creates the `my-assistant` sandbox, installs the 1claw plugin, and optional skills from `config/skills-to-install.txt`. When the script finishes, this container exits; you can remove it. |
| **1claw-interactive** | `ubuntu:24.04` | The **interactive runner**. Created by `npm run nemoclaw:interactive`. Gives you a bash prompt with openshell and NemoClaw pre-installed. |

Sandboxes (e.g. `my-assistant`) run as k3s pods inside the gateway container — they are **not** visible as separate Docker containers in `docker ps`. To connect to a sandbox, use `npm run connect` or `openshell sandbox connect my-assistant` (see 2.1).

### 2.1 Easiest: use the connect script (no install)

No NemoClaw install on your Mac needed. Run:

```bash
npm run connect
```

This uses `openshell sandbox connect` if available natively, otherwise runs it inside Docker (works on Intel Macs). Sandboxes are k3s pods managed by the gateway, so regular `docker exec` won't reach them.

You’re inside the same sandbox as in Path 1. Set `ONECLAW_*` and run `openclaw 1claw status` or `openclaw tui` as in step 1.5.

### 2.2 Optional: NemoClaw CLI on your Mac

If you want to run `nemoclaw my-assistant connect` from the Mac instead of `docker exec`, you need the CLI on the host. **Note:** NemoClaw’s `install.sh` runs **full onboarding** (its own gateway + sandbox on your Mac). That is **not** the Docker setup from Path 1—it’s a separate, native Mac stack.

- To **connect to the existing Docker sandbox** from Path 1: install the CLI (e.g. clone [NVIDIA/NemoClaw](https://github.com/NVIDIA/NemoClaw) and run `./install.sh`). When the installer asks to create a sandbox or start a gateway, you can skip or cancel if the Docker gateway is already running at `127.0.0.1:8080`. Then from your Mac run `nemoclaw my-assistant connect`; it will use that gateway and the sandbox you created in Path 1.
- To **run NemoClaw fully on your Mac (no Docker)**: run `./install.sh` and complete onboarding. That creates a new gateway and sandbox on the host. You are then not using the Docker setup from Path 1.

---

## Troubleshooting

- **Intel Mac: `openshell` CLI won't install natively**
  The `openshell` PyPI package has no `macosx_x86_64` wheel, so `pip install openshell` (or `uv tool install openshell`) fails on Intel Macs. Use `npm run gateway:start` — it detects this and runs the gateway inside Docker instead. The setup and interactive scripts also run openshell inside Docker, so they work on Intel Macs without changes.

- **Docker keychain errors on locked sessions**
  If Docker commands fail with `error getting credentials - err: exec: “docker-credential-desktop”: ... signal: killed` (common when your Mac session is locked or Screen Sharing disconnects), the macOS Keychain is unavailable. Fix: open `~/.docker/config.json` and change `”credsStore”: “desktop”` to `”credsStore”: “”`. This stores credentials in the config file instead of the Keychain. Re-lock will no longer break Docker pulls.

- **`openclaw tui` says “Missing gateway auth token”**
  The OpenClaw TUI needs its own gateway running inside the sandbox (separate from the OpenShell gateway). Start it first: `openclaw gateway run --auth token --token mytoken --allow-unconfigured &`, then `openclaw tui --token mytoken`. See step 1.5a.

- **`openclaw gateway run` says “Gateway start blocked: set gateway.mode=local”**
  Pass `--allow-unconfigured` to bypass: `openclaw gateway run --auth token --token mytoken --allow-unconfigured &`.

- **”Gateway failed to start”**
  Exit the container. On your Mac: Docker Desktop → Settings → Docker Engine. Add `”default-cgroupns-mode”: “host”` to the JSON. Apply & Restart. Start again from 1.1.

- **”Connection refused” when running `openshell sandbox list` inside the container**
  You skipped 1.2. Run: `openshell gateway add https://host.docker.internal:8080 --local`, then try again.

- **”invalid peer certificate: BadSignature” when running `openshell sandbox create` from your Mac**
  The CLI on your Mac is using TLS certs that don’t match the gateway. Use one of these:

  1. **Create the sandbox from inside Docker (recommended)**  
     Use Path 1: `npm run nemoclaw:interactive`, then inside the container run:
     ```bash
     openshell sandbox create --name my-assistant --from openclaw
     openshell policy set --policy /workspace/1claw-nemoclaw/config/1claw-openshell-policy.yaml my-assistant
     ```
     The CLI inside the container has the right gateway certs.

  2. **Use a plaintext gateway on your Mac**  
     Stop any existing gateway, then start one without TLS and create the sandbox:
     ```bash
     openshell gateway stop 2>/dev/null || true
     openshell gateway start --plaintext
     openshell gateway add http://127.0.0.1:8080 --local
     openshell sandbox create --name my-assistant --from openclaw
     openshell policy set --policy /Users/kevinjones/1claw-nemoclaw/config/1claw-openshell-policy.yaml my-assistant
     ```
     (Use your actual policy path if different.)

---

## What’s in this repo

| Path | Description |
|------|-------------|
| **config/1claw-openshell-policy.yaml** | OpenShell policy (1claw, NVIDIA, npm, GitHub). |
| **config/nemoclaw-1claw-blueprint.py** | Blueprint to apply 1claw policy to a sandbox. |
| [1claw-openclaw-plugin](https://github.com/1clawAI/1claw-openclaw-plugin) | OpenClaw plugin (cloned at setup time): `openclaw 1claw status`, `ls`, `fetch`, `put`, `rm`, etc. |

---

## How to test

**Without the sandbox (local):** From the repo, set `.env` with 1claw credentials, then run `npm test` (policy, blueprint, plugin).

**Inside the sandbox (full flow):** (1) On your Mac: `npm run gateway:start`, then `npm run setup:docker`. (2) Connect: `npm run connect`. (3) In the sandbox, set `ONECLAW_VAULT_ID`, `ONECLAW_AGENT_ID`, `ONECLAW_AGENT_API_KEY`, then run `openclaw 1claw status`, `openclaw 1claw ls`, `openclaw 1claw fetch path/to/secret`. For the TUI, see step 1.5a. If the openclaw image does not include the 1claw plugin, see [Testing guide](scripts/README-TESTING.md).

---

## Other commands

| Command | Description |
|--------|-------------|
| `npm run gateway:start` | Start the OpenShell plaintext gateway. Uses native CLI if available, otherwise runs in Docker (works on Intel Macs). |
| `npm run setup:docker` | One-shot: install, gateway, create sandbox, apply 1claw policy, optional 1claw agent self-enroll (if `ONECLAW_HUMAN_EMAIL` set), install 1claw plugin, and skills from `config/skills-to-install.txt` (requires `NVIDIA_API_KEY` in `.env`). |
| `npm run connect` | Connect to the sandbox from your Mac. Uses `openshell sandbox connect` (natively or via Docker). |
| `npm run plugin:upload` | Clone the [upstream 1claw plugin](https://github.com/1clawAI/1claw-openclaw-plugin), install deps, and upload to the sandbox (then in sandbox run `openclaw plugins install /sandbox/1claw-plugin`). |
| `npm run nemoclaw:interactive` | Start an interactive Docker shell for manual NemoClaw steps. |
| `npm test` | Run tests (policy, blueprint, plugin). |

**.env** — Copy `.env.example` to `.env` and set `ONECLAW_VAULT_ID`, `ONECLAW_AGENT_ID`, `ONECLAW_AGENT_API_KEY` for 1claw. Used in the sandbox and by tests.

---

## Links

- [1claw](https://1claw.xyz) · [OpenShell](https://docs.nvidia.com/openshell/latest/) · [NemoClaw](https://docs.nvidia.com/nemoclaw/latest/get-started/quickstart.html) · [Testing guide](scripts/README-TESTING.md)
