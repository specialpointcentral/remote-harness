// Agent-host bridge. The Harness PTY owns this process, while Paseo owns the agent.
import { execFileSync } from "node:child_process";
import { randomUUID } from "node:crypto";
import { readFileSync, realpathSync, rmSync, writeFileSync } from "node:fs";
import { createRequire } from "node:module";
import { basename, delimiter, dirname, join, resolve } from "node:path";
import { setTimeout as delay } from "node:timers/promises";
import { fileURLToPath, pathToFileURL } from "node:url";

const PASEO_VERSION = "0.15.3";
const SDK_ENTRY = "@getpaseo/client/internal/daemon-client";
const impl = dirname(fileURLToPath(import.meta.url));
const session = dirname(impl);
const harnessHome = resolve(session, "../..");
const lease = join(session, "paseo-lease.json");

class BridgeError extends Error {}

function json(path) {
  return JSON.parse(readFileSync(path, "utf8"));
}

function quote(value) {
  return "'" + value.replaceAll("'", "'\\''") + "'";
}

async function loadClient() {
  const bases = [join(harnessHome, "paseo")];
  for (const directory of (process.env.PATH ?? "").split(delimiter)) {
    if (!directory) continue;
    try {
      bases.push(dirname(realpathSync(join(directory, "paseo"))));
    } catch {
      // This PATH entry has no Paseo executable.
    }
  }
  for (const base of bases) {
    try {
      const entry = createRequire(join(resolve(base), "remote-harness.cjs")).resolve(SDK_ENTRY);
      if (json(join(dirname(entry), "..", "package.json")).version === PASEO_VERSION) {
        return (await import(pathToFileURL(entry).href)).DaemonClient;
      }
    } catch {
      // Try the next installation. This also covers a missing SDK dependency.
    }
  }
  throw new BridgeError(`Install @getpaseo/client@${PASEO_VERSION} under ${join(harnessHome, "paseo")}.`);
}

function daemonUrl() {
  try {
    const url = new URL(process.env.RH_PASEO_URL || "ws://127.0.0.1:6767/ws");
    if (["ws:", "wss:"].includes(url.protocol)
        && ["127.0.0.1", "[::1]", "localhost"].includes(url.hostname)
        && !url.username && !url.password && !url.search && !url.hash) {
      return url.href;
    }
  } catch {
    // Never print credentials accidentally embedded in the URL.
  }
  throw new BridgeError("RH_PASEO_URL must be a loopback WebSocket URL without credentials.");
}

async function bounded(ms, message, operation) {
  const cancel = new AbortController();
  try {
    return await Promise.race([
      operation(),
      delay(ms, undefined, { signal: cancel.signal }).then(() => { throw new BridgeError(message); }),
    ]);
  } finally {
    cancel.abort();
  }
}

async function providerConfig(client) {
  if (client.getLastServerInfoMessage()?.version !== PASEO_VERSION) {
    throw new BridgeError(`The agent host must run Paseo daemon ${PASEO_VERSION} for this bridge.`);
  }
  const { config } = await bounded(5000, "Could not read the Paseo daemon configuration.",
    () => client.getDaemonConfig());
  return config.providers;
}

async function checkClaude(client, claude) {
  const wrapper = join(harnessHome, "scripts", "paseo-claude.py");
  checkProviderCommand(claude, wrapper, "Claude");
  // Paseo deep-merges provider defaults. On some models the Anthropic SDK then lets
  // Options.settings replace extraArgs.settings, which would discard the Harness hooks.
  if ((claude?.options ?? claude?.params)?.settings !== undefined) {
    throw new BridgeError("Paseo Claude options.settings (or legacy params.settings) conflicts with Harness hooks.");
  }
  const { diagnostic } = await bounded(20000, "Paseo Claude diagnostics timed out.",
    () => client.getProviderDiagnostic("claude"));
  // This is the configured provider command's version, not the SSH login shell's Claude.
  const version = /^  Version: (\d+)\.(\d+)\.(\d+)\s+\(Claude Code\)/mi.exec(diagnostic);
  if (version) {
    const [major, minor, patch] = version.slice(1).map(Number);
    if (major > 2 || (major === 2 && (minor > 1 || (minor === 1 && patch >= 295)))) return;
  }
  throw new BridgeError("Paseo must use Claude Code 2.1.295 or newer to block failed routing hooks.");
}

function checkProviderCommand(config, wrapper, label) {
  const command = config?.command;
  const argv = command?.mode === "replace" ? command.argv : command;
  if (!Array.isArray(argv) || argv.length !== 1 || argv[0] !== wrapper) {
    throw new BridgeError(`Set the Paseo ${label} provider command to [${wrapper}] before using this launch.`);
  }
  return wrapper;
}

function checkCodexCommand(config) {
  return checkProviderCommand(config, join(harnessHome, "scripts", "native-codex.py"), "Codex");
}

function checkCodex(config, python) {
  const wrapper = checkCodexCommand(config);
  try {
    execFileSync(python, ["-EsB", wrapper, "check-harness-version"], { stdio: ["ignore", "ignore", "ignore"], timeout: 10000 });
  } catch {
    throw new BridgeError("Native Harness Codex requires Python 3.11+, codex-cli 0.167.0 and the private codex.json.");
  }
}

async function permissionMode(client, approval, provider) {
  if (provider === "codex") {
    const modes = { normal: "auto", auto: "auto-review", yolo: "full-access" };
    if (!Object.hasOwn(modes, approval)) throw new BridgeError("Invalid Paseo approval mode.");
    return modes[approval];
  }
  if (approval === "normal") return "default";
  if (approval === "yolo") return "bypassPermissions";
  if (approval !== "auto") throw new BridgeError("Invalid Paseo approval mode.");
  const { modes, error } = await bounded(10000, "Paseo Claude permission mode lookup timed out.",
    () => client.listProviderModes("claude"));
  if (error || !modes) throw new BridgeError("Could not read Paseo's Claude permission modes.");
  if (modes.some(({ id }) => id === "auto")) return "auto";
  console.warn("remote-harness: Paseo's Claude provider does not support auto. Using normal approvals.");
  return "default";
}

function agentEnvironment(provider) {
  const env = {};
  const keys = ["PATH", "SSH_CONNECTION", "SSH_CLIENT"];
  if (provider === "claude") keys.push("CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS",
    "CLAUDE_CODE_BASH_EDIT_DIFF", "USE_BUILTIN_RIPGREP");
  for (const key of keys) {
    if (process.env[key] !== undefined) env[key] = process.env[key];
  }
  if (!env.PATH || realpathSync(env.PATH.split(delimiter)[0]) !== join(session, "bin")) {
    throw new BridgeError("Paseo cannot start without the Harness PATH shims.");
  }
  return env;
}

function agentSettings(python, token) {
  const settings = json(join(session, "claude-settings.json"));
  const command = [quote(python), "-I", "-S", quote(join(impl, "paseo-guard.py")),
    quote(lease), quote(token)].join(" ");
  settings.hooks.PreToolUse.unshift({
    hooks: [{ type: "command", command, timeout: 5, onFailure: "block" }],
  });
  for (const name of ["paseo", ".paseo-workspaces", "scripts"]) {
    for (const tool of ["Read", "Edit"]) {
      settings.permissions.deny.push(`${tool}(/${join(harnessHome, name)}/**)`);
    }
  }
  // Keep the guard in the durable native config after the session directory is removed.
  // The command then fails and Claude's onFailure policy blocks tool calls.
  return JSON.stringify(settings);
}

function publishLease(token, config) {
  const result = execFileSync("/bin/ps",
    ["-ww", "-p", String(process.pid), "-o", "stat=", "-o", "lstart=", "-o", "args="],
    { encoding: "utf8", timeout: 2000 }).trim();
  const identity = result.replace(/^\S+\s+/, "");
  if (!identity || identity === result) throw new BridgeError("Could not identify the Paseo bridge process.");
  writeFileSync(lease, JSON.stringify({ pid: process.pid, identity, token, ...config }),
    { flag: "wx", mode: 0o600 });
}

async function main() {
  const [approval, python, provider = "claude"] = process.argv.slice(2);
  if (!python || !["claude", "codex"].includes(provider)) {
    throw new BridgeError("Start the Paseo bridge through the Harness launcher.");
  }
  const cwd = process.cwd();
  const env = agentEnvironment(provider);
  const agentId = randomUUID();
  const token = randomUUID();
  const settings = provider === "claude" ? agentSettings(python, token) : null;
  const systemPrompt = readFileSync(join(session, "rule.md"), "utf8");
  const DaemonClient = await loadClient();
  const quiet = () => {};
  const client = new DaemonClient({
    url: daemonUrl(),
    password: process.env.RH_PASEO_PASSWORD,
    clientId: `remote-harness-${agentId}`,
    clientType: "cli",
    logger: { debug: quiet, info: quiet, warn: quiet, error: quiet },
    connectTimeoutMs: 8000,
    reconnect: { enabled: true },
  });
  const stop = new AbortController();
  let leased = false;
  let createAttempted = false;
  let endedInPaseo = false;
  function revoke() {
    if (!leased) return;
    rmSync(lease, { force: true });
    leased = false;
  }
  function requestStop() {
    stop.abort();
    revoke();
  }
  const signals = ["SIGINT", "SIGTERM", "SIGHUP"];
  for (const signal of signals) process.on(signal, requestStop);
  let stage = "connect to the local Paseo daemon";
  try {
    await bounded(10000, "Could not connect to Paseo. Check RH_PASEO_URL and RH_PASEO_PASSWORD.",
      () => client.connect());
    if (stop.signal.aborted) return;
    stage = `verify the daemon's ${provider} provider`;
    const providers = await providerConfig(client);
    if (provider === "claude") await checkClaude(client, providers.claude);
    else checkCodex(providers.codex, python);
    if (stop.signal.aborted) return;
    const modeId = await permissionMode(client, approval, provider);
    if (stop.signal.aborted) return;
    const label = provider === "codex" ? "Codex" : "Claude";
    stage = `create the native ${label} session`;
    execFileSync(python, ["-EsB", join(impl, "native_workspace.py"), "reserve", harnessHome, cwd],
      { stdio: ["ignore", "ignore", "ignore"], timeout: 5000 });
    if (settings) writeFileSync(join(session, "paseo-claude-settings.json"), settings,
      { flag: "wx", mode: 0o600 });
    publishLease(token, { provider, approval, python, cwd, env });
    leased = true;
    createAttempted = true;
    const model = process.env.RH_PASEO_MODEL?.trim();
    const agent = await bounded(30000, "Native Paseo session creation timed out.",
      () => client.createAgent({
        agentId,
        idempotencyKey: agentId,
        provider,
        cwd,
        title: `Remote Harness · ${basename(cwd)}`,
        modeId,
        ...(model ? { model } : {}),
        ...(settings ? { systemPrompt, providerOptions: { extraArgs: { settings } },
                         env: { ...env, RH_CLAUDE_SESSION: session, RH_CLAUDE_TOKEN: token } }
                     : { env: { RH_CODEX_SESSION: session, RH_CODEX_TOKEN: token } }),
        labels: { "remote-harness": "true" },
      }));
    if (agent.id !== agentId) throw new BridgeError("Paseo returned an unexpected agent identity.");
    if (stop.signal.aborted) return;
    console.log(`remote-harness: Paseo ${label} agent ${agentId} is ready. Open it in Paseo.`);
    stage = `monitor the native ${label} session`;
    let failedSince;
    while (!stop.signal.aborted) {
      await delay(2000, undefined, { signal: stop.signal });
      let currentProviders;
      try {
        const snapshot = await client.fetchAgent({ agentId, timeout: 5000 });
        if (!snapshot || snapshot.agent.archivedAt) {
          endedInPaseo = true;
          break;
        }
        currentProviders = await providerConfig(client);
        failedSince = undefined;
      } catch {
        failedSince ??= Date.now();
        if (Date.now() - failedSince >= 30000) {
          throw new BridgeError("Lost contact with Paseo. Releasing the Harness session.");
        }
      }
      if (currentProviders) {
        if (provider === "codex") checkCodexCommand(currentProviders.codex);
        else checkProviderCommand(currentProviders.claude,
          join(harnessHome, "scripts", "paseo-claude.py"), "Claude");
      }
    }
  } catch (error) {
    if (!stop.signal.aborted) {
      throw error instanceof BridgeError ? error : new BridgeError(`Could not ${stage}.`);
    }
  } finally {
    try {
      revoke();
      if (createAttempted && !endedInPaseo) {
        try {
          await bounded(5000, "Paseo archive timed out.", () => client.archiveAgent(agentId));
        } catch {
          console.warn(`remote-harness: could not confirm archive of Paseo agent ${agentId}. Its tool lease has ended.`);
        }
      }
    } finally {
      await client.close();
      for (const signal of signals) process.off(signal, requestStop);
    }
  }
}

try {
  await main();
} catch (error) {
  console.error("remote-harness:", error instanceof BridgeError ? error.message : "Paseo bridge setup failed.");
  process.exitCode = 1;
}
