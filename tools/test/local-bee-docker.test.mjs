import test from 'node:test';
import assert from 'node:assert/strict';
import { OWNER_LABEL, IMAGES, inspectOwnedContainer,
  RELAY_PROGRAM, RELAY_PORTS, inspectOwnedRelay } from '../local-bee/docker.mjs';

const runId = 'ab'.repeat(16), networkId = 'cd'.repeat(32), imageId = `sha256:${'ef'.repeat(32)}`;
const expected = { runId, networkId, imageId, port: 1633 };
const inspected = () => ({ Id: '12'.repeat(32), Image: imageId, Config: { Labels: { [OWNER_LABEL]: runId } },
  State: { Running: true }, NetworkSettings: { Networks: { local: { NetworkID: networkId } },
    Ports: { '1633/tcp': [{ HostIp: '127.0.0.1', HostPort: '41234' }], '1634/tcp': null } } });
test('internal-only nodes need no published ports and reject even requested publication', () => {
  const info = inspected(); info.NetworkSettings.Ports = { '1633/tcp': null };
  assert.equal(inspectOwnedContainer(info, { ...expected, port: undefined }), undefined);
  info.HostConfig = { PortBindings: { '1633/tcp': [{ HostIp: '127.0.0.1', HostPort: '' }] } };
  assert.throws(() => inspectOwnedContainer(info, { ...expected, port: undefined }));
});
const relayInfo = () => ({ ...inspected(),
  Config: { Labels: { [OWNER_LABEL]: runId }, Cmd: ['-e', RELAY_PROGRAM], Entrypoint: ['node'], User: '1000:1000' },
  HostConfig: { ReadonlyRootfs: true, CapDrop: ['ALL'], SecurityOpt: ['no-new-privileges'] },
  NetworkSettings: { Networks: { internal: { NetworkID: networkId }, access: { NetworkID: '34'.repeat(32) } },
    Ports: Object.fromEntries(RELAY_PORTS.map((port, i) => [`${port}/tcp`, [{ HostIp: '127.0.0.1', HostPort: String(41000 + i) }]])) } });
const relayExpected = { ...expected, accessNetworkId: '34'.repeat(32) };
test('relay ownership requires fixed configuration, loopback ports and the two owned networks', () => {
  assert.equal(inspectOwnedRelay(relayInfo(), relayExpected)[8545], 'http://127.0.0.1:41000');
  for (const mutate of [
    info => { info.NetworkSettings.Ports['8545/tcp'][0].HostIp = '0.0.0.0'; },
    info => { info.Config.Cmd = ['-e', 'different code']; },
    info => { info.NetworkSettings.Networks.extra = { NetworkID: '56'.repeat(32) }; },
    info => { info.HostConfig.ReadonlyRootfs = false; },
  ]) { const info = relayInfo(); mutate(info); assert.throws(() => inspectOwnedRelay(info, relayExpected)); }
});
test('ownership proof requires exact image, run label, running state and one private network', () => {
  assert.ok(Object.values(IMAGES).every(image => !/latest|master/u.test(image)));
  assert.throws(() => inspectOwnedContainer(inspected(), { ...expected, runId: 'someone-else' }), /INVALID_LOCAL_RUN_ID/);
  assert.equal(inspectOwnedContainer(inspected(), expected), 'http://127.0.0.1:41234');
  for (const mutate of [
    info => { info.Config.Labels[OWNER_LABEL] = 'different'; },
    info => { info.Image = `sha256:${'11'.repeat(32)}`; },
    info => { info.State.Running = false; },
    info => { info.NetworkSettings.Networks.other = { NetworkID: '22'.repeat(32) }; },
    info => { info.NetworkSettings.Networks.local.NetworkID = '33'.repeat(32); },
  ]) { const info = inspected(); mutate(info); assert.throws(() => inspectOwnedContainer(info, expected)); }
});
test('ownership proof rejects public API bindings, extra exposed ports and malformed host ports', () => {
  for (const mutate of [
    info => { info.NetworkSettings.Ports['1633/tcp'][0].HostIp = '0.0.0.0'; },
    info => { info.NetworkSettings.Ports['1633/tcp'][0].HostPort = '70000'; },
    info => { info.NetworkSettings.Ports['1633/tcp'].push({ HostIp: '::', HostPort: '41234' }); },
    info => { info.NetworkSettings.Ports['1634/tcp'] = [{ HostIp: '127.0.0.1', HostPort: '41235' }]; },
  ]) { const info = inspected(); mutate(info); assert.throws(() => inspectOwnedContainer(info, expected)); }
});
