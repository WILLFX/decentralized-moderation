// Pure bootstrap tests: no browser, wallet, RPC or application is started.
import test from 'node:test';
import assert from 'node:assert/strict';
import {readFile} from 'node:fs/promises';
import vm from 'node:vm';
import {createHash, webcrypto} from 'node:crypto';

const wallet = await readFile(new URL('./fixture-wallet.js', import.meta.url), 'utf8');
const entry = await readFile(new URL('./fixture-entry.js', import.meta.url), 'utf8');
const selection = await readFile(new URL('./fixture-wallet-selection.js', import.meta.url), 'utf8');

async function assertStopped(window) {
  const app = {textContent: ''};
  const context = {window, document: {getElementById: () => app}};
  // The blocked branch must finish without importing the real loader.
  await vm.runInNewContext(`(async () => { ${entry}\n})()`, context);
  assert.match(app.textContent, /application was not started/);
}

test('an existing provider prevents application startup and is never called', async () => {
  let calls = 0;
  const realProvider = {request() { calls++; }};
  const window = {ethereum: realProvider};
  vm.runInNewContext(wallet, {window});
  assert.equal(window.ethereum, realProvider);
  assert.equal(window.__syntheticModeratorReady, undefined);
  await assertStopped(window);
  assert.equal(calls, 0);
});

test('synthetic requests stay on the fixture route and its provider cannot be replaced', async () => {
  const window = {};
  const requests = [];
  vm.runInNewContext(wallet, {window, fetch: async (url, options) => {
    requests.push({url, body: JSON.parse(options.body)});
    return {json: async () => ({result: '0x27d8'})};
  }});
  assert.equal(window.__syntheticModeratorReady, true);
  const descriptor = Object.getOwnPropertyDescriptor(window, 'ethereum');
  assert.equal(descriptor.configurable, false);
  assert.equal(descriptor.writable, false);
  assert.throws(() => Object.defineProperty(window, 'ethereum', {value: {}}), TypeError);
  assert.equal(await window.ethereum.request({method: 'eth_chainId', params: []}), '0x27d8');
  assert.deepEqual(requests, [{url: '/fixture/wallet', body: {method: 'eth_chainId', params: []}}]);
});

test('failure to protect the synthetic provider keeps the application stopped', async () => {
  const window = {};
  Object.defineProperty(window, 'ethereum', {get: () => undefined, configurable: false});
  assert.throws(() => vm.runInNewContext(wallet, {window}), /redefine property/);
  assert.equal(window.__syntheticModeratorReady, undefined);
  await assertStopped(window);
});

test('publisher event polling stays local and delivers a controlled account change', async () => {
  const window = {__syntheticFixtureEvents: true};
  let poll;
  const calls = [];
  vm.runInNewContext(wallet, {window, setInterval: fn => {poll = fn;}, fetch: async url => {
    calls.push(url);
    return {json: async () => [{name: 'accountsChanged', value: ['0x' + '60'.repeat(20)]}]};
  }});
  let account;
  window.ethereum.on('accountsChanged', values => {account = values[0];});
  await poll();
  assert.equal(account, '0x' + '60'.repeat(20));
  assert.deepEqual(calls, ['/fixture/events']);
});

test('the storage fault affects tab authoring only and can be cleared', async () => {
  class Storage { setItem(key, value) { this[key] = value; } }
  const window = {__syntheticFixtureEvents: true, sessionStorage: new Storage()};
  const local = new Storage();
  let poll;
  let fail = true;
  vm.runInNewContext(wallet, {window, Storage, setInterval: fn => {poll = fn;}, fetch: async () => ({json: async () => [{name: 'fixtureAuthoringStorageFault', value: fail}]})});
  await poll();
  assert.throws(() => window.sessionStorage.setItem('swarm-publisher-authoring-v1', 'new'), /Synthetic tab storage failure/);
  local.setItem('swarm-publisher-authoring-v1', 'local');
  window.sessionStorage.setItem('other-key', 'kept');
  assert.equal(local['swarm-publisher-authoring-v1'], 'local');
  fail = false;
  await poll();
  window.sessionStorage.setItem('swarm-publisher-authoring-v1', 'new');
  assert.equal(window.sessionStorage['swarm-publisher-authoring-v1'], 'new');
});

function selectionFixture(options = {}, existingProvider) {
  class Storage {
    setItem(key, value) { this[key] = String(value); }
    getItem(key) { return Object.hasOwn(this, key) ? this[key] : null; }
  }
  const events = new Map(), announcements = [], requests = [], acks = [];
  const window = {localStorage: new Storage(), sessionStorage: new Storage(),
    addEventListener(name, fn) { events.set(name, fn); },
    dispatchEvent(event) { announcements.push(event.detail); }};
  if (existingProvider) window.ethereum = existingProvider;
  const URL = {createObjectURL: () => 'blob:synthetic'};
  const originalSet = Storage.prototype.setItem, originalURL = URL.createObjectURL;
  let poll, queued = [];
  vm.runInNewContext(`${selection}(${JSON.stringify({mode: 'single', authorizationEvent: false, ...options})});`, {
    window, Storage, localStorage: window.localStorage, URL, crypto: webcrypto, TextEncoder,
    CustomEvent: class { constructor(type, value) { this.type = type; this.detail = value.detail; } },
    setInterval(fn, delay) { assert.equal(delay, 150); poll = fn; },
    fetch: async (url, options) => {
      if (url === '/fixture/events') return {json: async () => queued.splice(0)};
      assert.equal(url, '/fixture/wallet');
      const body = JSON.parse(options.body);
      if (body.method === 'fixture_ack') acks.push(body.params[0]);
      else requests.push(body);
      return {json: async () => ({result: ['0x' + '50'.repeat(20)]})};
    },
  });
  return {window, Storage, URL, announcements, requests, acks, originalSet, originalURL,
    announce: () => events.get('eip6963:requestProvider')?.(),
    poll: async (...values) => { queued.push(...values); await poll(); }};
}

for (const [mode, names, defaultId] of [
  ['multi', ['Alpha Wallet', 'Beta Wallet'], 'beta'], ['single', ['Alpha Wallet'], 'alpha'],
  ['announced-only', ['Alpha Wallet'], 'none'], ['legacy', [], 'alpha'], ['none', [], 'none'],
]) {
  test(`configured ${mode} provider preserves discovery and default selection`, async () => {
    const fixture = selectionFixture({mode});
    fixture.announce();
    assert.deepEqual(fixture.announcements.map(p => p.info.name), names);
    const descriptor = Object.getOwnPropertyDescriptor(fixture.window, 'ethereum');
    assert.equal(descriptor.configurable, false);
    assert.equal(descriptor.writable, mode !== 'none');
    await fixture.poll({kind: 'observe', seq: 1});
    assert.equal(fixture.acks[0].defaultId, defaultId);
    assert.deepEqual(Object.keys(fixture.acks[0]), ['seq', 'defaultId', 'listeners']);
    assert.equal(fixture.requests.length, 0);
  });
}

test('configured authorization event occurs before account access resolves', async () => {
  const fixture = selectionFixture({authorizationEvent: true});
  const order = [];
  fixture.window.ethereum.on('accountsChanged', () => order.push('event'));
  await fixture.window.ethereum.request({method: 'eth_requestAccounts'});
  order.push('resolved');
  assert.deepEqual(order, ['event', 'resolved']);
  assert.deepEqual(fixture.requests, [{method: 'eth_requestAccounts', params: ['alpha']}]);
});

test('request options retain fault scope and disclose only public records and a vault digest', async () => {
  const fixture = selectionFixture({requestStorageFaults: true, observeRequests: true, observeVault: true});
  const vault = '{"cipher":"synthetic encrypted bytes"}';
  fixture.window.localStorage.setItem('moderator-vote-vault-v1', vault);
  fixture.window.localStorage.setItem('moderator-requests-v1:one', '{"nonce":"0x9"}');
  await fixture.poll({kind: 'request-storage-fault', enabled: true, seq: 1});
  for (const storage of [fixture.window.localStorage, fixture.window.sessionStorage]) {
    assert.throws(() => storage.setItem('moderator-requests-v1:two', '{}'), /Synthetic storage failure/);
    storage.setItem('other-key', 'kept');
  }
  const ack = fixture.acks[0];
  assert.equal(ack.vaultFingerprint, createHash('sha256').update(vault).digest('hex'));
  assert.deepEqual(ack.requests, {'moderator-requests-v1:one': '{"nonce":"0x9"}'});
  assert.ok(!JSON.stringify(ack).includes('synthetic encrypted bytes'));
  assert.ok(!('recoveryExports' in ack));
  await fixture.poll({kind: 'request-storage-fault', enabled: false, seq: 2});
  fixture.window.localStorage.setItem('moderator-requests-v1:two', '{}');
});

test('recovery capture remains opt-in and excludes plaintext votes and unrelated files', async () => {
  const ordinary = selectionFixture();
  assert.equal(ordinary.URL.createObjectURL, ordinary.originalURL);
  const fixture = selectionFixture({captureRecovery: true});
  const encrypted = JSON.stringify({format: 'moderator-vote-vault', cipher: {data: 'encrypted'}});
  for (const [type, text] of [
    ['application/json', encrypted], ['text/plain', encrypted],
    ['application/json', JSON.stringify({format: 'moderator-vote-vault', votes: [], cipher: {data: 'bad'}})],
    ['application/json', JSON.stringify({format: 'other', cipher: {data: 'bad'}})],
  ]) assert.equal(fixture.URL.createObjectURL({type, text: async () => text}), 'blob:synthetic');
  await Promise.resolve();
  await fixture.poll({kind: 'observe', seq: 1});
  assert.deepEqual(fixture.acks[0].recoveryExports, [encrypted]);
});

test('configured hooks never run when an existing provider blocks the fixture', async () => {
  const real = {request() { throw new Error('must not call real provider'); }};
  const fixture = selectionFixture({requestStorageFaults: true, captureRecovery: true}, real);
  assert.equal(fixture.window.ethereum, real);
  assert.equal(fixture.window.__syntheticModeratorReady, undefined);
  assert.equal(fixture.Storage.prototype.setItem, fixture.originalSet);
  assert.equal(fixture.URL.createObjectURL, fixture.originalURL);
  await assertStopped(fixture.window);
});
