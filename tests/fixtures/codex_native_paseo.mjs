import { createRequire } from 'node:module';
import { createInterface } from 'node:readline';

const [action, modules, url, id] = process.argv.slice(2);
const require = createRequire(modules + '/../package.json');
if (action === 'serve') {
  const { createPaseoDaemon, loadConfig } = await import(require.resolve('@getpaseo/server'));
  const { default: pino } = await import(require.resolve('pino'));
  const config = loadConfig(process.env.PASEO_HOME, { env: process.env });
  config.speech = { providers: Object.fromEntries(
    ['dictationStt', 'voiceTurnDetection', 'voiceStt', 'voiceTts'].map(
      name => [name, { provider: 'local', explicit: true, enabled: false }])) };
  const daemon = await createPaseoDaemon(config, pino({ level: 'silent' }));
  await daemon.start();
  console.log(JSON.stringify({ port: daemon.getListenTarget().port }));
  process.once('SIGTERM', async () => {
    await daemon.stop();
    process.exit(0);
  });
} else if (action === 'approve') {
  const { DaemonClient } = await import(require.resolve('@getpaseo/client/internal/daemon-client'));
  const client = new DaemonClient({ url, clientId: 'rh-native-codex-test', connectTimeoutMs: 8000 });
  const input = createInterface({ input: process.stdin });
  try {
    await client.connect();
    const { agent } = await client.fetchAgent({ agentId: id });
    if (agent.provider !== 'codex') throw Error('Expected native Codex');
    await client.sendAgentMessage(id, 'RH_START_CHILD Start the fixture subagent.');
    const pending = await client.waitForFinish(id, 25000);
    if (pending.status !== 'permission') throw Error('Missing child approval: ' + JSON.stringify(pending));
    const [approval] = pending.final.pendingPermissions;
    console.log(JSON.stringify(approval));
    for await (const line of input) {
      if (line !== 'allow') throw Error('Unexpected approval response');
      await client.respondToPermission(id, approval.id, { behavior: 'allow' });
      break;
    }
  } finally {
    input.close();
    await client.close();
  }
}
