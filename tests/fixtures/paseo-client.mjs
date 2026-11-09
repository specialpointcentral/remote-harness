// Fake daemon behind the SDK surface. The tests run the real injector, bridge and hook.
import { execSync } from "node:child_process";
import { existsSync, renameSync, writeFileSync } from "node:fs";
import { join } from "node:path";

const state = process.env.PASEO_TEST_STATE;

function record(name, value) {
  const target = join(state, name);
  writeFileSync(target + ".tmp", JSON.stringify(value));
  renameSync(target + ".tmp", target);
}

export class DaemonClient {
  constructor(options) {
    if (options.password !== "fixture-secret" || options.url !== "ws://127.0.0.1:6767/ws") {
      throw new Error("Fixture expected loopback daemon authentication");
    }
  }

  async connect() {}
  async close() {}

  getLastServerInfoMessage() {
    return { version: "0.15.3" };
  }

  async getDaemonConfig() {
    return { config: { providers: { claude: { command: [
      process.env.PASEO_TEST_CLAUDE_COMMAND ?? join(process.env.RH_HOME, "scripts", "paseo-claude.py"),
    ] } } } };
  }

  async getProviderDiagnostic() {
    const version = process.env.PASEO_TEST_CLAUDE_VERSION ?? "2.1.319";
    return { provider: "claude", diagnostic: `Claude Code\n  Version: ${version} (Claude Code)` };
  }

  async listProviderModes() {
    return { provider: "claude", modes: [{ id: "auto", label: "Auto" }] };
  }

  async createAgent(request) {
    this.request = request;
    record("created", request);
    return { id: request.agentId, status: "idle", archivedAt: null };
  }

  async fetchAgent({ agentId }) {
    const archivedAt = existsSync(join(state, "archive-in-app")) ? new Date().toISOString() : null;
    record("idle", { agentId });
    return { agent: { id: agentId, status: "idle", archivedAt }, project: null };
  }

  async archiveAgent(agentId) {
    const settings = JSON.parse(this.request.providerOptions.extraArgs.settings);
    const { command } = settings.hooks.PreToolUse.find((hook) => !hook.matcher).hooks[0];
    let leaseLive = true;
    try {
      execSync(command, { input: '{"tool_name":"Read"}', stdio: ["pipe", "pipe", "pipe"] });
    } catch {
      leaseLive = false;
    }
    record("archive-called", { agentId, leaseLive });
    return { archivedAt: new Date().toISOString() };
  }
}
