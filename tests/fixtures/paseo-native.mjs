// Loopback integration test helper. Installed Paseo packages are supplied by the operator.
import { createPaseoDaemon, loadConfig } from "@getpaseo/server";
import { DaemonClient } from "@getpaseo/client/internal/daemon-client";
import pino from "pino";
import { setTimeout as delay } from "node:timers/promises";

async function serve() {
  const config = loadConfig(process.env.PASEO_HOME, { env: process.env });
  const speech = ["dictationStt", "voiceTurnDetection", "voiceStt", "voiceTts"];
  config.speech = { providers: Object.fromEntries(
    speech.map(key => [key, { provider: "local", explicit: true, enabled: false }]),
  ) };
  const daemon = await createPaseoDaemon(config, pino({ level: "silent" }));
  await daemon.start();
  console.log(daemon.getListenTarget().port);
  process.once("SIGTERM", async () => {
    await daemon.stop();
    process.exit(0);
  });
}

async function drive(url, agentId) {
  const client = new DaemonClient({ url, clientId: "rh-test-client", connectTimeoutMs: 8000 });
  try {
    await client.connect();
    const { agent } = await client.fetchAgent({ agentId });
    if (agent.provider !== "claude") throw new Error("Expected native Claude agent");
    await client.sendAgentMessage(agentId, "Run the fixture command once.");
    const pending = await client.waitForFinish(agentId, 30000);
    if (pending.status !== "permission") throw new Error(`Expected approval, got ${pending.status}`);
    const [permission] = pending.final.pendingPermissions;
    await client.respondToPermission(agentId, permission.id, { behavior: "allow" });
    for (let attempt = 0; attempt < 50; attempt++) {
      const snapshot = await client.fetchAgent({ agentId, timeout: 2000 });
      if (!snapshot.agent.pendingPermissions.length) break;
      await delay(100);
    }
    const done = await client.waitForFinish(agentId, 30000);
    if (done.status !== "idle") throw new Error(`Expected idle agent, got ${done.status}`);
  } finally {
    await client.close();
  }
}

async function rejectExtra(url, agentId) {
  const client = new DaemonClient({ url, clientId: "rh-test-extra-chat", connectTimeoutMs: 8000 });
  let extra;
  try {
    await client.connect();
    const { agent } = await client.fetchAgent({ agentId });
    extra = await client.createAgent({ provider: "claude", cwd: agent.cwd,
      title: "Unregistered fixture chat", model: "claude-sonnet-4-6", modeId: "bypassPermissions" });
    await client.sendAgentMessage(extra.id, "Run the fixture command once.");
    const done = await client.waitForFinish(extra.id, 30000);
    if (done.status !== "error") throw new Error(`Unregistered chat was not blocked: ${done.status}`);
  } finally {
    if (extra) await client.archiveAgent(extra.id);
    await client.close();
  }
}

const [operation, ...args] = process.argv.slice(2);
if (operation === "serve") await serve();
else if (operation === "reject-extra") await rejectExtra(...args);
else await drive(...args);
