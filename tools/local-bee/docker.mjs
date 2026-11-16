import { execFile } from 'node:child_process';
import { promisify } from 'node:util';
import { fail } from '../collections.mjs';

const execute = promisify(execFile);
export const OWNER_LABEL = 'org.swarm-discovery.local-run';
export const IMAGES = Object.freeze({
  bee: 'ethersphere/bee-factory-queen:v2.8.2',
  anvil: 'ghcr.io/foundry-rs/foundry:v1.7.1',
  relay: 'node:22.14.0-alpine3.21',
});
const idPattern = /^[0-9a-f]{64}$/u;
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
