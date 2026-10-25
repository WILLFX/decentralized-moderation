import { execFile } from 'node:child_process';
import { promisify } from 'node:util';
import { randomUUID } from 'node:crypto';
import { fail } from '../collections.mjs';

const execute = promisify(execFile);
export const OWNER_LABEL = 'org.swarm-discovery.local-run';
export const IMAGES = Object.freeze({
  bee: 'ethersphere/bee-factory-queen:v2.8.2',
  anvil: 'ghcr.io/foundry-rs/foundry:v1.7.1',
  relay: 'node:22.14.0-alpine3.21',
});
const idPattern = /^[0-9a-f]{64}$/u;
export function newRunId() { return randomUUID().replaceAll('-', ''); }
export function validRunId(value) {
  if (typeof value !== 'string' || !/^[0-9a-f]{32}$/u.test(value)) fail('INVALID_LOCAL_RUN_ID');
  return value;
}
export async function docker(args, timeout = 120000) {
  try {
    const result = await execute('docker', args, { timeout, maxBuffer: 2 * 1024 * 1024, windowsHide: true });
    return result.stdout.trim();
  } catch { fail('DOCKER_COMMAND_FAILED'); }
}
export async function beeDiagnosticLogs(id) {
  if (!idPattern.test(id)) fail('INVALID_DOCKER_ID');
  try {
    const { stdout, stderr } = await execute('docker', ['logs', '--tail', '80', id], {
      timeout: 15000, maxBuffer: 256 * 1024, windowsHide: true });
    return (stdout + stderr).split('\n').filter(line => !/password|private.?key|mnemonic|secret|salt|swarm\.key/iu.test(line)).join('\n').slice(-32000);
  } catch { return 'Bee logs unavailable'; }
}
export function storageArguments({ runId, networkId, imageId, keysDirectory, addresses }) {
  validRunId(runId);
  if (!idPattern.test(networkId) || !/^sha256:[0-9a-f]{64}$/u.test(imageId)) fail('INVALID_DOCKER_ID');
  const common = ['--label', `${OWNER_LABEL}=${runId}`, '--network', networkId];
  return {
    chain: ['create', ...common, '--name', `swarm-local-${runId}-storage`, '--network-alias', 'storage',
      '--entrypoint', '/usr/local/bin/anvil', imageId,
      '--host', '0.0.0.0', '--port', '8545', '--chain-id', '1337', '--accounts', '20',
      '--balance', '10000', '--block-time', '1', '--hardfork', 'prague'],
    bee(index, beeImageId) {
      if (!Number.isInteger(index) || index < 0 || index > 4 || !/^sha256:[0-9a-f]{64}$/u.test(beeImageId)) fail('INVALID_BEE_NODE');
      if (typeof keysDirectory !== 'string' || !keysDirectory.startsWith('/') || /[\u0000-\u001f,]/u.test(keysDirectory)) fail('INVALID_KEYS_DIRECTORY');
      const addressKeys = ['postageStamp', 'swapPriceOracle', 'stakeRegistry', 'redistribution', 'swapFactory', 'bzzToken'];
      if (!addresses || addressKeys.some(key => !/^0x[0-9a-f]{40}$/iu.test(addresses[key]))
          || !Number.isSafeInteger(addresses.postageStampStartBlock) || addresses.postageStampStartBlock < 1) fail('INVALID_STORAGE_ADDRESSES');
      // Fresh tmpfs hides the image's saved blockchain/chunk state. Only this
      // run's disposable test keystore directory is mounted, with no host P2P port.
      return ['create', ...common, '--name', `swarm-local-${runId}-bee-${index}`, '--network-alias', `bee-${index}`,
        '--tmpfs', '/home/bee/.bee:uid=999,gid=999,mode=0700',
        '--mount', `type=bind,src=${keysDirectory}/${index},dst=/home/bee/.bee/keys`,
        '--entrypoint', '/usr/local/bin/bee', beeImageId, 'start', '--full-node',
        '--api-addr=:1633', '--p2p-addr=:1634', '--data-dir=/home/bee/.bee',
        '--blockchain-rpc-endpoint=http://storage:8545', '--block-time=1',
        '--password=isolated-local-test', '--verbosity=3', '--network-id=1337', '--mainnet=false',
        '--allow-private-cidrs', '--cors-allowed-origins=*', '--skip-postage-snapshot', '--warmup-time=1s',
        '--swap-enable', '--swap-initial-deposit=100000000000000000',
        `--postage-stamp-address=${addresses.postageStamp}`, `--price-oracle-address=${addresses.swapPriceOracle}`,
        `--staking-address=${addresses.stakeRegistry}`, `--redistribution-address=${addresses.redistribution}`,
        `--swap-factory-address=${addresses.swapFactory}`, `--bzz-token-address=${addresses.bzzToken}`,
        `--postage-stamp-start-block=${addresses.postageStampStartBlock}`];
    },
  };
}
export function inspectOwnedContainer(value, { runId, networkId, imageId, port, running = true }) {
  validRunId(runId);
  if (!idPattern.test(value?.Id) || value.Config?.Labels?.[OWNER_LABEL] !== runId
      || value.Image !== imageId || (running && value.State?.Running !== true)) fail('LOCAL_CONTAINER_OWNERSHIP_FAILED');
  const networks = Object.values(value.NetworkSettings?.Networks ?? {});
  if (networks.length !== 1 || networks[0].NetworkID !== networkId) fail('LOCAL_CONTAINER_NETWORK_FAILED');
  const bindings = value.NetworkSettings?.Ports ?? {};
  if (port === undefined) {
    if (Object.values(bindings).some(entries => entries?.length)
        || Object.values(value.HostConfig?.PortBindings ?? {}).some(entries => entries?.length)) fail('LOCAL_PORT_EXPOSURE_REJECTED');
    return;
  }
  if (Object.entries(bindings).some(([key, entries]) => entries?.length && key !== `${port}/tcp`)) fail('LOCAL_PORT_EXPOSURE_REJECTED');
  const entries = bindings[`${port}/tcp`];
  if (!Array.isArray(entries) || entries.length !== 1 || entries[0].HostIp !== '127.0.0.1'
      || !/^[1-9][0-9]{0,4}$/u.test(entries[0].HostPort) || Number(entries[0].HostPort) > 65535) fail('LOCAL_PORT_EXPOSURE_REJECTED');
  return `http://127.0.0.1:${entries[0].HostPort}`;
}
// This is a fixed TCP relay, not a configurable HTTP proxy. Each listener has
// exactly one destination on the internal network. Nodes have no external route.
export const RELAY_PROGRAM = `
const net = require('node:net');
for (const [port, host, target] of [[8545,'storage',8545], ...Array.from({length:5},(_,i)=>[1633+i,'bee-'+i,1633])]) {
  net.createServer(client => {
    const upstream = net.createConnection({host, port:target});
    const close = () => { client.destroy(); upstream.destroy(); };
    client.on('error', close); upstream.on('error', close);
    client.setTimeout(300000, close); upstream.setTimeout(300000, close);
    client.pipe(upstream).pipe(client);
    client.on('close', () => upstream.destroy()); upstream.on('close', () => client.destroy());
  }).listen(port, '0.0.0.0');
}
`;
export const RELAY_PORTS = Object.freeze([8545, 1633, 1634, 1635, 1636, 1637]);
export function relayArguments({ runId, networkId, imageId }) {
  validRunId(runId);
  if (!idPattern.test(networkId) || !/^sha256:[0-9a-f]{64}$/u.test(imageId)) fail('INVALID_DOCKER_ID');
  return ['create', '--label', `${OWNER_LABEL}=${runId}`, '--name', `swarm-local-${runId}-relay`,
    '--network', networkId, '--read-only', '--cap-drop', 'ALL', '--security-opt', 'no-new-privileges', '--user', '1000:1000',
    ...RELAY_PORTS.flatMap(port => ['--publish', `127.0.0.1::${port}`]),
    '--entrypoint', 'node', imageId, '-e', RELAY_PROGRAM];
}
export function inspectOwnedRelay(value, { runId, networkId, accessNetworkId, imageId }) {
  validRunId(runId);
  if (!idPattern.test(value?.Id) || value.Config?.Labels?.[OWNER_LABEL] !== runId
      || value.Image !== imageId || value.State?.Running !== true) fail('LOCAL_RELAY_OWNERSHIP_FAILED');
  const networks = Object.values(value.NetworkSettings?.Networks ?? {}).map(network => network.NetworkID).sort();
  if (JSON.stringify(networks) !== JSON.stringify([networkId, accessNetworkId].sort())) fail('LOCAL_RELAY_NETWORK_FAILED');
  if (JSON.stringify(value.Config?.Cmd) !== JSON.stringify(['-e', RELAY_PROGRAM])
      || JSON.stringify(value.Config?.Entrypoint) !== JSON.stringify(['node'])
      || value.HostConfig?.ReadonlyRootfs !== true || value.Config?.User !== '1000:1000'
      || JSON.stringify(value.HostConfig?.CapDrop) !== JSON.stringify(['ALL'])
      || !value.HostConfig?.SecurityOpt?.some(option => /^no-new-privileges(?::true)?$/u.test(option))) fail('LOCAL_RELAY_CONFIG_CHANGED');
  const bindings = value.NetworkSettings?.Ports ?? {};
  if (Object.keys(bindings).length !== RELAY_PORTS.length) fail('LOCAL_PORT_EXPOSURE_REJECTED');
  const endpoints = {};
  for (const port of RELAY_PORTS) {
    const entries = bindings[`${port}/tcp`];
    if (!Array.isArray(entries) || entries.length !== 1 || entries[0].HostIp !== '127.0.0.1'
        || !/^[1-9][0-9]{0,4}$/u.test(entries[0].HostPort) || Number(entries[0].HostPort) > 65535) fail('LOCAL_PORT_EXPOSURE_REJECTED');
    endpoints[port] = `http://127.0.0.1:${entries[0].HostPort}`;
  }
  return endpoints;
}
export async function inspectContainer(id) {
  if (!idPattern.test(id)) fail('INVALID_DOCKER_ID');
  return JSON.parse(await docker(['inspect', id]))[0];
}
export async function removeOwnedResources(state) {
  validRunId(state.runId);
  // Exact recorded IDs only; never enumerate/remove someone else's stack.
  const failures = [];
  for (const id of [...state.containers].reverse()) {
    try {
      const info = await inspectContainer(id);
      if (info.Config?.Labels?.[OWNER_LABEL] !== state.runId) fail('LOCAL_CONTAINER_OWNERSHIP_FAILED');
      await docker(['rm', '--force', id]);
    } catch { failures.push(id); }
  }
  for (const networkId of [state.accessNetworkId, state.networkId].filter(Boolean)) {
    if (failures.length) break;
    try {
      if (!idPattern.test(networkId)) fail('INVALID_DOCKER_ID');
      const network = JSON.parse(await docker(['network', 'inspect', networkId]))[0];
      if (network.Labels?.[OWNER_LABEL] !== state.runId) fail('LOCAL_NETWORK_OWNERSHIP_FAILED');
      await docker(['network', 'rm', networkId]);
    } catch { failures.push(networkId); }
  }
  return failures;
}
