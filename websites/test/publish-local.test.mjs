import test from 'node:test';
import assert from 'node:assert/strict';
import { resolve, join } from 'node:path';
import { sessionPaths, verifyPublicRoundTrip } from '../scripts/publish-local.mjs';

test('publication only accepts a running session with recovery under its saved run', () => {
  const base = resolve('delivery-fixture');
  const session = { status: 'running', home: 'http://127.0.0.1:51280/', rpc: 'http://127.0.0.1:51282',
    sourceRun: join(base, 'run'), recovery: join(base, 'run/recovery') };
  assert.equal(sessionPaths(session, base).environment, join(base, 'run/recovery/environment/environment.json'));
  for (const change of [{status:'stopped'}, {home:'https://example.com'}, {rpc:'http://127.0.0.1:1234'},
    {sourceRun:resolve('unrelated')}, {recovery:join(base, 'different-run/recovery')}]) {
    assert.throws(() => sessionPaths({...session, ...change}, base));
  }
});

const reference = 'a'.repeat(64);
const collection = { entries: [
  {name:'index.html', bytes:Buffer.from('html')},
  {name:'loader.js', bytes:Buffer.from('js')},
  {name:'style.css', bytes:Buffer.from('css')},
  {name:'pkg/app.wasm', bytes:Buffer.from([0,97,115,109,1,0,0,0])},
] };
function fakeBee({badBytes=false, wasmType='application/wasm'} = {}) {
  return {request: async path => {
    const entry = collection.entries.find(e => path === `/bzz/${reference}/${e.name}`);
    assert.ok(entry);
    const type = entry.name.endsWith('.wasm') ? wasmType : entry.name.endsWith('.js') ? 'text/javascript'
      : entry.name.endsWith('.css') ? 'text/css' : 'text/html; charset=utf-8';
    return {bytes: badBytes ? Buffer.from('changed') : entry.bytes, type};
  }};
}
test('public front-door round trip includes browser Wasm MIME verification', async () => {
  await verifyPublicRoundTrip(fakeBee(), collection, reference);
});
test('correct Wasm bytes with a nonexecutable MIME type are rejected', async () => {
  await assert.rejects(verifyPublicRoundTrip(fakeBee({wasmType:'application/octet-stream'}), collection, reference),
    /PUBLIC_ASSET_MEDIA_TYPE_MISMATCH/);
});
test('changed public bytes fail closed before success is recorded', async () => {
  await assert.rejects(verifyPublicRoundTrip(fakeBee({badBytes:true}), collection, reference),
    /PUBLIC_ASSET_ROUND_TRIP_MISMATCH/);
});
