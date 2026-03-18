/// <reference types="node" />
/**
 * openclaw-1claw-plugin.ts
 * ──────────────────────────────────────────────────────────────
 * OpenClaw plugin: 1claw secret management
 *
 * Adds `openclaw 1claw <command>` to the OpenClaw CLI so agents
 * running inside an OpenShell / NemoClaw sandbox can fetch, store,
 * and inspect secrets from a 1claw HSM-backed vault without ever
 * pasting credentials into a prompt.
 *
 * Commands
 * --------
 *   openclaw 1claw enroll [--email <email>] [--name <name>] — self-enroll (no creds); API key emailed to human
 *   openclaw 1claw status                   — health check
 *   openclaw 1claw fetch <path>             — fetch + print a secret
 *   openclaw 1claw put   <path> <value>     — store a secret
 *   openclaw 1claw ls    [prefix]           — list secrets
 *   openclaw 1claw rotate <path> <value>    — rotate a secret
 *   openclaw 1claw inspect <text>           — run threat detection
 *   openclaw 1claw env   <path>             — load env bundle into shell
 *
 * Configuration (env vars, resolved in order)
 * -------------------------------------------
 *   ONECLAW_VAULT_ID     — vault to operate on
 *   ONECLAW_AGENT_ID     — agent identity
 *   ONECLAW_API_KEY      — agent API key (ocv_…)
 *   ONECLAW_TOKEN        — static JWT (skips auth exchange)
 *   ONECLAW_BASE_URL     — override API base (default: https://api.1claw.xyz)
 *   ONECLAW_MCP_URL      — override MCP URL (default: https://mcp.1claw.xyz/mcp)
 *   ONECLAW_USE_SHROUD   — route inference through Shroud TEE proxy (true/false)
 *
 * Installation
 * ------------
 *   Place this file in your OpenClaw plugins directory and register it:
 *
 *   // openclaw.config.ts
 *   import oneclaw from "./openclaw-1claw-plugin";
 *   export default { plugins: [oneclaw] };
 *
 * Dependencies (add to package.json)
 * ------------------------------------
 *   npm install node-fetch chalk ora
 * ──────────────────────────────────────────────────────────────
 */

// ── Types ─────────────────────────────────────────────────────────────────

interface OneclawConfig {
  baseUrl: string;
  mcpUrl: string;
  vaultId: string;
  agentId: string;
  apiKey: string;
  staticToken?: string;
  useShroud: boolean;
}

interface Secret {
  path: string;
  type: string;
  version: number;
  expires_at?: string;
}

interface AuthResponse {
  token?: string;
  access_token?: string;
  expires_in?: number;
}

interface EnrollResponse {
  agent_id: string;
}

interface InspectResult {
  score: number;
  safe: boolean;
  flags: string[];
  redacted: string;
}

// ── Plugin definition ─────────────────────────────────────────────────────

export interface OpenClawPlugin {
  name: string;
  version: string;
  description: string;
  commands: Record<string, OpenClawCommand>;
}

export interface OpenClawCommand {
  description: string;
  usage: string;
  handler: (args: string[], ctx: PluginContext) => Promise<void>;
}

export interface PluginContext {
  log: (msg: string) => void;
  error: (msg: string) => void;
  exit: (code: number) => void;
}

// ── Config loader ─────────────────────────────────────────────────────────

function loadConfig(): OneclawConfig {
  const cfg: OneclawConfig = {
    baseUrl:     process.env.ONECLAW_BASE_URL  ?? "https://api.1claw.xyz",
    mcpUrl:      process.env.ONECLAW_MCP_URL   ?? "https://mcp.1claw.xyz/mcp",
    vaultId:     process.env.ONECLAW_VAULT_ID  ?? "",
    agentId:     process.env.ONECLAW_AGENT_ID  ?? "",
    apiKey:      process.env.ONECLAW_API_KEY   ?? "",
    staticToken: process.env.ONECLAW_TOKEN,
    useShroud:   process.env.ONECLAW_USE_SHROUD === "true",
  };

  if (!cfg.vaultId) {
    throw new Error(
      "ONECLAW_VAULT_ID is not set.\n" +
      "  export ONECLAW_VAULT_ID=<vault-id>"
    );
  }
  if (!cfg.staticToken && (!cfg.agentId || !cfg.apiKey)) {
    throw new Error(
      "Set ONECLAW_TOKEN (static JWT) or both ONECLAW_AGENT_ID and ONECLAW_API_KEY."
    );
  }

  return cfg;
}

// ── HTTP client ───────────────────────────────────────────────────────────

async function apiRequest<T>(
  cfg: OneclawConfig,
  method: "GET" | "POST" | "PUT" | "DELETE",
  path: string,
  token: string,
  body?: unknown
): Promise<T> {
  const url = `${cfg.baseUrl}${path}`;
  const headers: Record<string, string> = {
    "Content-Type": "application/json",
    "Authorization": `Bearer ${token}`,
  };

  const res = await fetch(url, {
    method,
    headers,
    body: body !== undefined ? JSON.stringify(body) : undefined,
  });

  if (!res.ok) {
    const text = await res.text().catch(() => "");
    throw new Error(`1claw API ${method} ${path} → ${res.status}: ${text}`);
  }

  const text = await res.text();
  if (!text) return undefined as T;
  return JSON.parse(text) as T;
}

// ── Auth ──────────────────────────────────────────────────────────────────

/** Cache the JWT for the life of this process. */
let _cachedToken: string | null = null;
let _tokenExpiry  = 0;

async function getToken(cfg: OneclawConfig): Promise<string> {
  // Use static token if provided
  if (cfg.staticToken) return cfg.staticToken;

  // Return cached token if still valid (with 60s buffer)
  if (_cachedToken && Date.now() < _tokenExpiry - 60_000) {
    return _cachedToken;
  }

  const res = await fetch(`${cfg.baseUrl}/v1/auth/agent-token`, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ agent_id: cfg.agentId, api_key: cfg.apiKey }),
  });

  if (!res.ok) {
    const text = await res.text().catch(() => "");
    throw new Error(`1claw auth failed (${res.status}): ${text}`);
  }

  const data = (await res.json()) as AuthResponse;
  const token = data.token ?? data.access_token;
  if (!token) throw new Error("No token in auth response");

  _cachedToken = token;
  _tokenExpiry = Date.now() + (data.expires_in ?? 300) * 1000;

  return token;
}

// ── Enroll (no auth required) ──────────────────────────────────────────────

/**
 * `openclaw 1claw enroll [--email <email>] [--name <name>]`
 * Self-enroll with 1claw: creates an agent, API key is emailed to the human.
 * Use when ONECLAW_AGENT_ID / ONECLAW_API_KEY are not set.
 * See https://docs.1claw.xyz/docs/guides/agent-self-onboarding
 */
async function cmdEnroll(ctx: PluginContext, args: string[]): Promise<void> {
  const baseUrl = process.env.ONECLAW_BASE_URL ?? "https://api.1claw.xyz";
  let humanEmail = process.env.ONECLAW_HUMAN_EMAIL ?? "";
  let agentName = process.env.ONECLAW_AGENT_NAME ?? "my-assistant";
  let description = "NemoClaw / OpenShell sandbox agent";

  for (let i = 0; i < args.length; i++) {
    if (args[i] === "--email" && args[i + 1]) {
      humanEmail = args[++i];
    } else if (args[i] === "--name" && args[i + 1]) {
      agentName = args[++i];
    } else if (args[i] === "--description" && args[i + 1]) {
      description = args[++i];
    } else if (!args[i].startsWith("--") && !humanEmail) {
      humanEmail = args[i];
    }
  }

  if (!humanEmail) {
    ctx.error(
      "Human email is required.\n" +
      "  openclaw 1claw enroll --email you@example.com\n" +
      "  or set ONECLAW_HUMAN_EMAIL and run: openclaw 1claw enroll"
    );
    ctx.exit(1);
  }

  ctx.log("Enrolling agent with 1claw (API key will be emailed to the human)…\n");

  const res = await fetch(`${baseUrl}/v1/agents/enroll`, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({
      name: agentName,
      human_email: humanEmail,
      description,
    }),
  });

  if (!res.ok) {
    const text = await res.text().catch(() => "");
    ctx.error(`Enroll failed (${res.status}): ${text}`);
    ctx.exit(1);
  }

  const data = (await res.json()) as EnrollResponse;
  const agentId = data.agent_id;

  ctx.log(`✓ Agent enrolled. Agent ID: ${agentId}\n`);
  ctx.log("Next steps:");
  ctx.log("  1. Check the inbox for " + humanEmail + " for the API key (ocv_…).");
  ctx.log("  2. In the 1claw dashboard, create or select a vault and add a policy for this agent.");
  ctx.log("  3. Set in this environment:");
  ctx.log(`     export ONECLAW_AGENT_ID="${agentId}"`);
  ctx.log("     export ONECLAW_API_KEY=\"ocv_...\"   # from the email");
  ctx.log("     export ONECLAW_VAULT_ID=\"<your-vault-id>\"");
  ctx.log("  4. Run: openclaw 1claw status");
}

// ── Command handlers ──────────────────────────────────────────────────────

/**
 * `openclaw 1claw status`
 * Checks connectivity to the vault API and MCP endpoint.
 */
async function cmdStatus(cfg: OneclawConfig, ctx: PluginContext): Promise<void> {
  ctx.log("Checking 1claw connectivity…\n");

  // Vault API
  try {
    const token = await getToken(cfg);
    const data = await apiRequest<{ secrets: Secret[] }>(
      cfg, "GET", `/v1/vaults/${cfg.vaultId}/secrets`, token
    );
    ctx.log(`✓ Vault API        reachable  (${data.secrets?.length ?? 0} secrets)`);
  } catch (e) {
    ctx.error(`✗ Vault API        FAILED: ${(e as Error).message}`);
  }

  // MCP hosted endpoint
  try {
    const res = await fetch(cfg.mcpUrl, { method: "GET" });
    ctx.log(`✓ MCP Server       reachable  (${res.status})`);
  } catch (e) {
    ctx.error(`✗ MCP Server       FAILED: ${(e as Error).message}`);
  }

  // Shroud proxy (if enabled)
  if (cfg.useShroud) {
    try {
      const res = await fetch("https://shroud.1claw.xyz/health");
      ctx.log(`✓ Shroud TEE proxy reachable  (${res.status})`);
    } catch (e) {
      ctx.error(`✗ Shroud TEE proxy FAILED: ${(e as Error).message}`);
    }
  }

  ctx.log(`\nVault ID:  ${cfg.vaultId}`);
  ctx.log(`Agent ID:  ${cfg.agentId || "(static token)"}`);
  ctx.log(`Shroud:    ${cfg.useShroud ? "enabled" : "disabled"}`);
}

/**
 * `openclaw 1claw ls [prefix]`
 * Lists secret paths (metadata only — no values).
 */
async function cmdList(
  cfg: OneclawConfig,
  ctx: PluginContext,
  prefix?: string
): Promise<void> {
  const token = await getToken(cfg);
  const data = await apiRequest<{ secrets: Secret[] }>(
    cfg, "GET", `/v1/vaults/${cfg.vaultId}/secrets`, token
  );

  let secrets = data.secrets ?? [];
  if (prefix) secrets = secrets.filter(s => s.path.startsWith(prefix));

  if (secrets.length === 0) {
    ctx.log(prefix ? `No secrets matching prefix "${prefix}".` : "Vault is empty.");
    return;
  }

  const maxPath = Math.max(...secrets.map(s => s.path.length), 4);

  ctx.log(`${"PATH".padEnd(maxPath)}  TYPE          VER  EXPIRES`);
  ctx.log(`${"─".repeat(maxPath)}  ────────────  ───  ─────────────────────`);

  for (const s of secrets) {
    const expiry = s.expires_at
      ? new Date(s.expires_at).toLocaleString()
      : "—";
    ctx.log(
      `${s.path.padEnd(maxPath)}  ${(s.type ?? "?").padEnd(12)}  ${String(s.version ?? "?").padEnd(3)}  ${expiry}`
    );
  }
  ctx.log(`\n${secrets.length} secret(s) found.`);
}

/**
 * `openclaw 1claw fetch <path>`
 * Fetches and prints the decrypted value of a secret.
 * The value is printed once and NOT stored anywhere.
 */
async function cmdFetch(
  cfg: OneclawConfig,
  ctx: PluginContext,
  secretPath: string
): Promise<void> {
  if (!secretPath) throw new Error("Usage: openclaw 1claw fetch <path>");

  const token  = await getToken(cfg);
  const data   = await apiRequest<{ value: string; version: number }>(
    cfg, "GET",
    `/v1/vaults/${cfg.vaultId}/secrets/${secretPath.replace(/^\//, "")}`,
    token
  );

  // Print the value to stdout so it can be captured by scripts.
  // It is NOT stored in a variable that persists beyond this call.
  ctx.log(data.value);
}

/**
 * `openclaw 1claw put <path> <value>`
 * Creates or updates a secret.
 */
async function cmdPut(
  cfg: OneclawConfig,
  ctx: PluginContext,
  secretPath: string,
  value: string
): Promise<void> {
  if (!secretPath || !value) throw new Error("Usage: openclaw 1claw put <path> <value>");

  const token = await getToken(cfg);
  const data  = await apiRequest<{ version: number }>(
    cfg, "PUT",
    `/v1/vaults/${cfg.vaultId}/secrets/${secretPath.replace(/^\//, "")}`,
    token,
    { type: "password", value }
  );

  ctx.log(`✓ Secret stored at "${secretPath}" (version ${data.version})`);
}

/**
 * `openclaw 1claw rotate <path> <new-value>`
 * Stores a new version of an existing secret.
 */
async function cmdRotate(
  cfg: OneclawConfig,
  ctx: PluginContext,
  secretPath: string,
  newValue: string
): Promise<void> {
  if (!secretPath || !newValue) throw new Error("Usage: openclaw 1claw rotate <path> <new-value>");

  const token = await getToken(cfg);
  const data  = await apiRequest<{ version: number }>(
    cfg, "PUT",
    `/v1/vaults/${cfg.vaultId}/secrets/${secretPath.replace(/^\//, "")}`,
    token,
    { type: "password", value: newValue }
  );

  ctx.log(`✓ Secret rotated at "${secretPath}" — now version ${data.version}`);
}

/**
 * `openclaw 1claw rm <path>` (or `delete`)
 * Deletes a secret at the given path. The agent can remove secrets it created.
 */
async function cmdDelete(
  cfg: OneclawConfig,
  ctx: PluginContext,
  secretPath: string
): Promise<void> {
  if (!secretPath) throw new Error("Usage: openclaw 1claw rm <path>");

  const token = await getToken(cfg);
  await apiRequest<unknown>(
    cfg,
    "DELETE",
    `/v1/vaults/${cfg.vaultId}/secrets/${secretPath.replace(/^\//, "")}`,
    token
  );

  ctx.log(`✓ Secret removed at "${secretPath}"`);
}

/**
 * `openclaw 1claw inspect <text>`
 * Runs 1claw's 6-layer threat detection on a piece of text.
 * Useful for checking a prompt before forwarding it to an LLM.
 */
async function cmdInspect(
  cfg: OneclawConfig,
  ctx: PluginContext,
  text: string
): Promise<void> {
  if (!text) throw new Error("Usage: openclaw 1claw inspect <text>");

  // inspect_content works without vault credentials (local-only mode)
  // but we try with auth first for the full cloud pipeline.
  let token: string | undefined;
  try { token = await getToken(cfg); } catch (_) { /* local-only fallback */ }

  const headers: Record<string, string> = { "Content-Type": "application/json" };
  if (token) headers["Authorization"] = `Bearer ${token}`;

  const res = await fetch(`${cfg.baseUrl}/v1/inspect`, {
    method: "POST",
    headers,
    body: JSON.stringify({ content: text }),
  });

  if (!res.ok) {
    const t = await res.text().catch(() => "");
    throw new Error(`Inspect failed (${res.status}): ${t}`);
  }

  const result = (await res.json()) as InspectResult;

  ctx.log(`Safe:     ${result.safe ? "✓ yes" : "✗ NO"}`);
  ctx.log(`Score:    ${result.score.toFixed(3)} ${result.score > 0.5 ? "(⚠ high)" : "(ok)"}`);
  ctx.log(`Flags:    ${result.flags?.length ? result.flags.join(", ") : "none"}`);
  ctx.log(`Redacted: ${result.redacted ?? "(no redaction)"}`);
}

/**
 * `openclaw 1claw env <path>`
 * Fetches an env_bundle secret (KEY=VALUE lines) and exports the values
 * as shell exports, which the parent shell can eval.
 *
 * Usage in shell:
 *   eval "$(openclaw 1claw env my-service/env)"
 */
async function cmdEnv(
  cfg: OneclawConfig,
  ctx: PluginContext,
  secretPath: string
): Promise<void> {
  if (!secretPath) throw new Error("Usage: openclaw 1claw env <path>");

  const token = await getToken(cfg);
  const data  = await apiRequest<{ value: string }>(
    cfg, "GET",
    `/v1/vaults/${cfg.vaultId}/secrets/${secretPath.replace(/^\//, "")}`,
    token
  );

  // Parse KEY=VALUE lines and emit shell exports
  const lines = data.value.split(/\r?\n/).filter(l => l.trim() && !l.startsWith("#"));
  for (const line of lines) {
    const idx = line.indexOf("=");
    if (idx < 0) continue;
    const key = line.slice(0, idx).trim();
    const val = line.slice(idx + 1).trim().replace(/^["']|["']$/g, "");
    // emit to stdout so the parent shell can eval this
    process.stdout.write(`export ${key}=${JSON.stringify(val)}\n`);
  }
}

// ── Plugin manifest ───────────────────────────────────────────────────────

const oneclawPlugin: OpenClawPlugin = {
  name: "1claw",
  version: "0.1.0",
  description:
    "HSM-backed secret management for OpenClaw agents via 1claw.xyz. " +
    "Fetch, store, and inspect credentials at runtime without exposing them in prompts.",

  commands: {

    enroll: {
      description: "Self-enroll with 1claw (no credentials). API key is emailed to the human.",
      usage: "openclaw 1claw enroll --email <email> [--name <agent-name>]",
      async handler(args, ctx) {
        await cmdEnroll(ctx, args);
      },
    },

    status: {
      description: "Check connectivity to the 1claw vault API and MCP server.",
      usage: "openclaw 1claw status",
      async handler(_args, ctx) {
        const cfg = loadConfig();
        await cmdStatus(cfg, ctx);
      },
    },

    ls: {
      description: "List secrets in the vault (metadata only, no values).",
      usage: "openclaw 1claw ls [<prefix>]",
      async handler(args, ctx) {
        const cfg = loadConfig();
        await cmdList(cfg, ctx, args[0]);
      },
    },

    fetch: {
      description: "Fetch and print the decrypted value of a secret.",
      usage: "openclaw 1claw fetch <path>",
      async handler(args, ctx) {
        const cfg = loadConfig();
        await cmdFetch(cfg, ctx, args[0]);
      },
    },

    put: {
      description: "Store a new secret or update an existing one.",
      usage: "openclaw 1claw put <path> <value>",
      async handler(args, ctx) {
        const cfg = loadConfig();
        await cmdPut(cfg, ctx, args[0], args[1]);
      },
    },

    rotate: {
      description: "Create a new version of an existing secret.",
      usage: "openclaw 1claw rotate <path> <new-value>",
      async handler(args, ctx) {
        const cfg = loadConfig();
        await cmdRotate(cfg, ctx, args[0], args[1]);
      },
    },

    rm: {
      description: "Delete a secret. Use to remove secrets the agent added.",
      usage: "openclaw 1claw rm <path>",
      async handler(args, ctx) {
        const cfg = loadConfig();
        await cmdDelete(cfg, ctx, args[0]);
      },
    },

    delete: {
      description: "Alias for rm — delete a secret.",
      usage: "openclaw 1claw delete <path>",
      async handler(args, ctx) {
        const cfg = loadConfig();
        await cmdDelete(cfg, ctx, args[0]);
      },
    },

    inspect: {
      description: "Run 1claw's 6-layer threat detection on a piece of text.",
      usage: "openclaw 1claw inspect <text>",
      async handler(args, ctx) {
        const cfg = loadConfig();
        await cmdInspect(cfg, ctx, args.join(" "));
      },
    },

    env: {
      description: "Load an env_bundle secret and emit shell exports (use with eval).",
      usage: 'eval "$(openclaw 1claw env <path>)"',
      async handler(args, ctx) {
        const cfg = loadConfig();
        await cmdEnv(cfg, ctx, args[0]);
      },
    },

    help: {
      description: "Show this help message.",
      usage: "openclaw 1claw help",
      async handler(_args, ctx) {
        ctx.log("openclaw 1claw — secret management commands\n");
        for (const [name, cmd] of Object.entries(oneclawPlugin.commands)) {
          if (name === "help") continue;
          ctx.log(`  ${cmd.usage.padEnd(50)} ${cmd.description}`);
        }
        ctx.log("\nEnvironment variables:");
        ctx.log("  openclaw 1claw put <path> <value>   — add/update secret");
        ctx.log("  openclaw 1claw rm <path>            — delete secret (alias: delete)");
        ctx.log("");
        ctx.log("  ONECLAW_VAULT_ID    (required) vault to operate on");
        ctx.log("  ONECLAW_AGENT_ID    agent identity");
        ctx.log("  ONECLAW_API_KEY     agent API key (ocv_…)");
        ctx.log("  ONECLAW_TOKEN       static JWT (skips auth exchange)");
        ctx.log("  ONECLAW_HUMAN_EMAIL for enroll: email to receive API key");
        ctx.log("  ONECLAW_AGENT_NAME  for enroll: agent name (default: my-assistant)");
        ctx.log("  ONECLAW_BASE_URL    API base URL override");
        ctx.log("  ONECLAW_MCP_URL     MCP server URL override");
        ctx.log("  ONECLAW_USE_SHROUD  true to route LLM traffic through Shroud");
      },
    },
  },
};

export default oneclawPlugin;

// ── Standalone CLI (for testing outside OpenClaw) ─────────────────────────

if (require.main === module) {
  const ctx: PluginContext = {
    log:  (msg) => console.log(msg),
    error: (msg) => console.error(msg),
    exit: (code) => process.exit(code),
  };

  const [,, subcmd, ...rest] = process.argv;
  const command = oneclawPlugin.commands[subcmd ?? "help"];

  if (!command) {
    console.error(`Unknown command: ${subcmd}`);
    console.error(`Available: ${Object.keys(oneclawPlugin.commands).join(", ")}`);
    process.exit(1);
  }

  command.handler(rest, ctx).catch((err) => {
    console.error(`Error: ${(err as Error).message}`);
    process.exit(1);
  });
}
