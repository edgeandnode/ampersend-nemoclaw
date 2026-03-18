# Testing the 1claw + OpenShell / NemoClaw setup

This guide walks through testing all three integration pieces **without** requiring a full OpenShell/NemoClaw install. You can then optionally apply the policy and run the agent inside a sandbox.

---

## Run tests (local)

From repo root:

```bash
npm test
```

This runs: policy validation, blueprint dry-run (if `ONECLAW_*` set), and plugin status.

To run the **full setup in Docker** (create sandbox, install 1claw plugin and optional skills) on your Mac:

```bash
openshell gateway start --plaintext   # on Mac, one-time
npm run setup:docker
```

Then connect with `openshell sandbox connect my-assistant` or `docker exec -it <container> bash` and run `openclaw 1claw status` inside.

---

## Prerequisites

- **Node 18+** (for the OpenClaw plugin tests)
- **Python 3.8+** and pip (for the NemoClaw blueprint)
- **1claw credentials** (vault, agent, API key) from [1claw.xyz](https://1claw.xyz)

Optional for full flow:

- **OpenShell** CLI (`openshell` in PATH) — to apply policy and create sandboxes
- **NemoClaw** — to launch sandboxed OpenClaw with the blueprint

---

## 1. Install dependencies

```bash
# From repo root
cd /path/to/1claw-nemoclaw

# Node (for plugin tests)
yarn install
# or: npm install

# Python (for blueprint tests)
pip install -r requirements.txt
```

---

## 2. Set credentials (for blueprint + plugin tests)

```bash
export ONECLAW_VAULT_ID="your-vault-id"
export ONECLAW_AGENT_ID="your-agent-id"
export ONECLAW_API_KEY="ocv_..."
```

Or use a static JWT for the plugin only:

```bash
export ONECLAW_VAULT_ID="your-vault-id"
export ONECLAW_TOKEN="eyJ..."   # short-lived JWT from 1claw
```

---

## 3. Run tests

### All at once

```bash
yarn test
# or: npm test
```

This runs:

1. **Policy** — validates `config/1claw-openshell-policy.yaml` (no creds needed).
2. **Blueprint** — resolve + plan only (`--skip-apply`); skips if env vars missing.
3. **Plugin** — `openclaw 1claw status` via the test runner; skips if creds missing.

### Individually

```bash
# Policy only (no credentials)
yarn test:policy

# Blueprint dry-run (needs ONECLAW_*)
yarn test:blueprint

# Plugin status (needs ONECLAW_VAULT_ID + agent creds or ONECLAW_TOKEN)
yarn test:plugin:status
yarn test:plugin:help
```

---

## 4. Plugin commands (standalone)

From repo root, with credentials set:

```bash
# Help
node scripts/test-plugin-runner.mjs help

# Status (vault + MCP reachability)
node scripts/test-plugin-runner.mjs status

# List secrets (metadata only)
node scripts/test-plugin-runner.mjs ls
node scripts/test-plugin-runner.mjs ls "api-keys/"

# Fetch a secret (prints value to stdout)
node scripts/test-plugin-runner.mjs fetch "path/to/secret"
```

The same commands are available inside OpenClaw as `openclaw 1claw <command>` once the plugin is registered in your OpenClaw config.

---

## 5. Run NemoClaw in Docker and test 1claw inside the sandbox

To run the agent inside a NemoClaw sandbox and use `openclaw 1claw` there:

### One-shot setup (recommended)

On your Mac, from the **1claw-nemoclaw** repo root:

```bash
openshell gateway start --plaintext   # one-time, on Mac
npm run setup:docker
```

This installs dependencies in a container, creates the sandbox, applies the 1claw policy, installs the 1claw plugin, and optionally installs OpenClaw skills from `config/skills-to-install.txt`. Then connect (see README Path 1 and Path 2).

### Optional: interactive Docker shell

For manual steps (e.g. without using the one-shot setup):

```bash
npm run nemoclaw:interactive
# Inside container: register gateway, create sandbox, etc. See README.
```

### After setup: get the plugin in (if not using setup:docker)

You need the 1claw OpenClaw plugin **inside** the sandbox and registered in OpenClaw’s config.

- **If you can mount this repo** when creating the sandbox (e.g. bind-mount `1claw-nemoclaw` to `/sandbox/1claw-nemoclaw`), the plugin path in the sandbox is  
  `/sandbox/1claw-nemoclaw/config/openclaw-1claw-plugin.ts`.
- **Otherwise**, copy the plugin file into the sandbox (e.g. `docker cp config/openclaw-1claw-plugin.ts <container>:/sandbox/openclaw-1claw-plugin.ts`), then in OpenClaw config add:

  `import oneclaw from "/sandbox/openclaw-1claw-plugin";` and include `oneclaw` in the `plugins` array.

Then:

```bash
nemoclaw my-assistant connect
# inside the sandbox:
export ONECLAW_VAULT_ID="<vault-id>" ONECLAW_AGENT_ID="<agent-id>" ONECLAW_API_KEY="ocv_..."
openclaw 1claw status
openclaw 1claw ls
openclaw tui   # optional: chat with the agent
```

---

## 6. Apply policy to a real OpenShell sandbox (without NemoClaw)

If you have the OpenShell CLI installed:

```bash
openshell policy set --sandbox <sandbox-name> --file config/1claw-openshell-policy.yaml
openshell policy get --sandbox <sandbox-name>   # verify
```

---

## 7. Full blueprint (create/update sandbox)

Without `--skip-apply`, the blueprint creates or updates the sandbox and applies the 1claw policy:

```bash
python3 config/nemoclaw-1claw-blueprint.py \
  --sandbox my-assistant \
  --vault-id "$ONECLAW_VAULT_ID" \
  --agent-id "$ONECLAW_AGENT_ID" \
  --agent-api-key "$ONECLAW_API_KEY"
```

Then connect and test inside the sandbox:

```bash
nemoclaw my-assistant connect
# inside sandbox:
export ONECLAW_VAULT_ID=... ONECLAW_AGENT_ID=... ONECLAW_API_KEY=...
openclaw 1claw status
openclaw 1claw ls
```

---

## Troubleshooting

| Issue | What to check |
|-------|----------------|
| `ONECLAW_VAULT_ID is not set` | Export vault/agent/api-key (or ONECLAW_TOKEN) before running plugin or blueprint. |
| `Auth failed: 401` | Wrong agent ID or API key; confirm in 1claw dashboard. |
| `openshell: command not found` | Policy file test still passes; install OpenShell to apply policy or run sandbox. |
| `tsx` not found when running plugin test | Run `yarn install` (tsx is a devDependency) or `npx tsx scripts/test-plugin-runner.ts status`. |
| Python `ModuleNotFoundError` | Run `pip install -r requirements.txt`. |

---

## File reference

| File | Purpose |
|------|--------|
| `config/1claw-openshell-policy.yaml` | OpenShell network + FS policy (1claw + NVIDIA + npm/GitHub). |
| `config/nemoclaw-1claw-blueprint.py` | NemoClaw blueprint: resolve → plan → apply → validate. |
| `config/openclaw-1claw-plugin.ts` | OpenClaw plugin: `openclaw 1claw status/ls/fetch/put/...` |
| `scripts/test-all.sh` | Runs policy + blueprint (dry-run) + plugin status. |
| `scripts/test-openshell-policy.sh` | Validates policy YAML. |
| `scripts/test-blueprint.sh` | Blueprint with `--skip-apply`. |
| `scripts/test-plugin-runner.mjs` | Invokes the TS plugin via tsx for local testing. |
| `scripts/setup-nemoclaw-in-docker.sh` | One-shot Docker setup: sandbox, policy, 1claw plugin, optional skills. |
