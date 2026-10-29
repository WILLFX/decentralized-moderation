// Pure bootstrap tests: no browser, wallet, RPC or application is started.
import test from 'node:test';
import assert from 'node:assert/strict';
import {readFile} from 'node:fs/promises';
import vm from 'node:vm';

const wallet = await readFile(new URL('./fixture-wallet.js', import.meta.url), 'utf8');
const entry = await readFile(new URL('./fixture-entry.js', import.meta.url), 'utf8');

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
