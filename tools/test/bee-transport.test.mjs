import test from 'node:test';
import assert from 'node:assert/strict';
import { createCollectionTar } from '../collections.mjs';
import { localEndpoint, createLocalBee, readUploadedAsset } from '../local-bee/bee.mjs';
const root = 'http://127.0.0.1:1633';
const batch = 'ab'.repeat(32), ref = 'cd'.repeat(32);
const bytes = value => new TextEncoder().encode(value);
const code = value => error => { assert.equal(error.code, value); return true; };
const response = (value, type = 'application/json') => new Response(typeof value === 'string' ? value : JSON.stringify(value),
  { status: 200, headers: { 'content-type': type } });
test('collection tar is reproducible and readable using independent POSIX header checks', () => {
  const entries = [{ name: 'index.html', bytes: bytes('<h1>Swarm</h1>') }, { name: 'nested/app.mjs', bytes: bytes('export const ok = true;') }];
  const tar = createCollectionTar(entries);
  assert.deepEqual(tar, createCollectionTar([...entries].reverse()));
  const found = {}; let offset = 0;
  while (tar[offset] !== 0) {
    const header = tar.subarray(offset, offset + 512);
    const field = (start, length) => header.subarray(start, start + length).toString('ascii').replace(/\0.*$/su, '').trim();
    assert.equal(field(257, 6), 'ustar'); assert.equal(field(136, 12), '00000000000');
    const checksum = Number.parseInt(field(148, 8), 8);
    let sum = 0; for (let i = 0; i < 512; i++) sum += i >= 148 && i < 156 ? 32 : header[i];
    assert.equal(sum, checksum);
    const size = Number.parseInt(field(124, 12), 8), name = field(0, 100);
    found[name] = tar.subarray(offset + 512, offset + 512 + size);
    offset += 512 + Math.ceil(size / 512) * 512;
  }
  assert.equal(tar.length - offset, 1024);
  for (const entry of entries) assert.deepEqual(found[entry.name], Buffer.from(entry.bytes));
});
test('tar rejects traversal, duplicate names, unknown byte types and a missing entry page', () => {
  const index = { name: 'index.html', bytes: bytes('index') };
  for (const name of ['/root', '../secret', 'a/../secret', 'a\\secret', '.', 'a/'.repeat(60)]) {
    assert.throws(() => createCollectionTar([index, { name, bytes: bytes('bad') }]), code('INVALID_COLLECTION'));
  }
  assert.throws(() => createCollectionTar([index, index]), code('INVALID_COLLECTION'));
  assert.throws(() => createCollectionTar([{ name: 'index.html', bytes: 'bad' }]), code('INVALID_COLLECTION'));
  assert.throws(() => createCollectionTar([{ name: 'other', bytes: bytes('bad') }]), code('COLLECTION_INDEX_REQUIRED'));
});
test('local Bee accepts only explicit loopback HTTP endpoints without userinfo or coercion', () => {
  for (const value of [root, 'http://localhost:1633/', 'http://[::1]:1633']) assert.equal(localEndpoint(value), new URL(value).origin);
  let coerced = 0;
  for (const value of ['https://bee.example.test', 'http://bee.example.test:1633', 'http://127.0.0.1',
    'http://user:password@127.0.0.1:1633', root + '/private', root + '/?token=secret', root + '/#',
    { toString() { coerced++; return root; } }]) assert.throws(() => localEndpoint(value), code('LOCAL_ENDPOINT_REQUIRED'));
  assert.equal(coerced, 0);
});
test('Bee byte upload binds postage, raw unencrypted storage and safe transport options', async () => {
  let captured;
  const bee = createLocalBee({ endpoint: root, fetchImpl: async (url, init) => {
    captured = { url, init }; return response({ reference: ref });
  } });
  const payload = bytes('raw local content'); assert.equal(await bee.uploadBytes(payload, batch), ref);
  assert.equal(captured.url, root + '/bytes'); assert.equal(captured.init.headers['swarm-postage-batch-id'], batch);
  assert.equal(captured.init.headers['swarm-encrypt'], 'false'); assert.equal(captured.init.headers['swarm-deferred-upload'], 'true');
  assert.equal(captured.init.headers['swarm-pin'], 'true');
  assert.equal(captured.init.redirect, 'error'); assert.equal(captured.init.credentials, 'omit'); assert.deepEqual(captured.init.body, payload);
});
test('Bee rejects invalid references and oversized content before inappropriate access', async () => {
  let calls = 0;
  const bee = createLocalBee({ endpoint: root, fetchImpl: async () => { calls++; return response({ reference: '0'.repeat(64) }); } });
  await assert.rejects(bee.uploadBytes(bytes('ok'), batch), code('INVALID_BEE_REFERENCE'));
  await assert.rejects(bee.uploadBytes(bytes('ok'), 'bad'), code('INVALID_BEE_REFERENCE'));
  await assert.rejects(bee.uploadBytes(new Uint8Array(1024 * 1024 + 1), batch), code('INVALID_LOCAL_CONTENT'));
  assert.equal(calls, 1);
});
function collectionTransport({ wrongAsset = false, scriptType = 'text/javascript', rootType = 'text/html' } = {}) {
  const entries = [{ name: 'index.html', bytes: bytes('<h1>Local</h1>') }, { name: 'app.mjs', bytes: bytes('export const ok = true;') }];
  const calls = [];
  const fetchImpl = async (url, init) => {
    calls.push({ url, init });
    if (init.method === 'POST') return response({ reference: ref });
    const name = url.endsWith('/') ? 'index.html' : url.split('/').at(-1);
    const entry = entries.find(item => item.name === name); assert.ok(entry);
    return response(wrongAsset && name === 'app.mjs' ? 'wrong bytes' : new TextDecoder().decode(entry.bytes), name === 'app.mjs' ? scriptType : rootType);
  };
  return { collection: { role: 'search', entries, tar: createCollectionTar(entries) }, calls, fetchImpl };
}
test('Bee collections use an index document and verify every emitted asset through the returned reference', async () => {
  const f = collectionTransport(); const bee = createLocalBee({ endpoint: root, fetchImpl: f.fetchImpl });
  const result = await bee.uploadSite(f.collection, batch);
  assert.equal(result.reference, ref); assert.equal(result.assetsVerified, 2);
  assert.equal(f.calls[0].init.headers['swarm-collection'], 'true'); assert.equal(f.calls[0].init.headers['swarm-index-document'], 'index.html');
  assert.ok(f.calls.slice(1).every(call => call.url.startsWith(root + '/bzz/' + ref + '/')));
});
test('collection round trips reject changed bytes and module/index MIME types that browsers cannot execute', async () => {
  for (const [options, expected] of [[{ wrongAsset: true }, 'BEE_SITE_ASSET_MISMATCH'],
    [{ scriptType: 'application/octet-stream' }, 'BEE_SCRIPT_MEDIA_TYPE'], [{ rootType: 'text/plain' }, 'BEE_SITE_INDEX_MISMATCH']]) {
    const f = collectionTransport(options); const bee = createLocalBee({ endpoint: root, fetchImpl: f.fetchImpl });
    await assert.rejects(bee.uploadSite(f.collection, batch), code(expected));
  }
});
test('new upload readback tolerates two matching 404s without repeating the upload', async () => {
  const path = '/bzz/' + ref + '/runtime/adapter.mjs', waits = [], retries = [];
  let reads = 0;
  const read = async requested => {
    assert.equal(requested, path);
    if (++reads < 3) throw Object.assign(new Error('missing'), { code: 'BEE_HTTP_ERROR', http: { status: 404, method: 'GET', path } });
    return { bytes: bytes('verified later'), type: 'text/javascript' };
  };
  const found = await readUploadedAsset(read, path, { wait: async ms => waits.push(ms), onRetry: value => retries.push(value) });
  assert.equal(reads, 3); assert.deepEqual(waits, [1000, 2000]); assert.equal(retries.length, 2);
  assert.equal(new TextDecoder().decode(found.bytes), 'verified later');
});
test('new upload readback keeps persistent 404, other HTTP errors and wrong request identity visible', async () => {
  const path = '/bzz/' + ref + '/app.mjs';
  for (const [http, expectedReads] of [[{ status: 404, method: 'GET', path }, 3],
    [{ status: 500, method: 'GET', path }, 1], [{ status: 404, method: 'POST', path }, 1],
    [{ status: 404, method: 'GET', path: '/other' }, 1]]) {
    let reads = 0;
    const error = Object.assign(new Error('readback'), { code: 'BEE_HTTP_ERROR', http });
    await assert.rejects(readUploadedAsset(async () => { reads++; throw error; }, path, { wait: async () => {} }), value => value === error);
    assert.equal(reads, expectedReads);
  }
});
test('collection upload retries only its missing GET and still verifies the returned bytes', async () => {
  const fixture = collectionTransport(); let uploads = 0, failed = false;
  const bee = createLocalBee({ endpoint: root, fetchImpl: async (url, options) => {
    if (options.method === 'POST') uploads++;
    else if (url.endsWith('/app.mjs') && !failed) { failed = true; return new Response('{}', { status: 404 }); }
    return fixture.fetchImpl(url, options);
  } });
  const result = await bee.uploadSite(fixture.collection, batch);
  assert.equal(result.assetsVerified, 2); assert.equal(uploads, 1); assert.equal(failed, true);
});
test('invalid request paths and response limits fail before transport', async () => {
  let calls = 0; const bee = createLocalBee({ endpoint: root, fetchImpl: async () => { calls++; return response('ok'); } });
  for (const path of ['https://remote.test/', '//remote.test/', '/x/../secret', '/x#fragment', '/x\n']) {
    await assert.rejects(bee.request(path), code('INVALID_BEE_REQUEST'));
  }
  await assert.rejects(bee.request('/health', {}, Infinity), code('INVALID_BEE_REQUEST'));
  assert.equal(calls, 0);
});
test('bounded responses reject oversized streams and declared truncation', async () => {
  let bee = createLocalBee({ endpoint: root, fetchImpl: async () => response('oversized') });
  await assert.rejects(bee.request('/bytes/' + ref, {}, 3), code('BEE_RESPONSE_SIZE_LIMIT'));
  bee = createLocalBee({ endpoint: root, fetchImpl: async () => new Response('short', { headers: { 'content-length': '20' } }) });
  await assert.rejects(bee.request('/health'), code('BEE_TRUNCATED_RESPONSE'));
});
test('total deadlines cover an uncooperative fetch and errors do not expose provider details', async () => {
  const bee = createLocalBee({ endpoint: root, timeoutMs: 10, fetchImpl: () => new Promise(() => {}) });
  await assert.rejects(bee.request('/health'), code('BEE_TIMEOUT'));
  const failed = createLocalBee({ endpoint: root, fetchImpl: async () => { throw Object.assign(new Error('private provider detail'), { code: 'PRIVATE' }); } });
  await assert.rejects(failed.request('/health'), error => error.code === 'BEE_ACCESS_FAILED' && !error.message.includes('private'));
});
test('Bee HTTP errors preserve status and request identity without copying response secrets', async () => {
  const bee = createLocalBee({ endpoint: root, fetchImpl: async () => new Response('private upstream detail', { status: 500 }) });
  await assert.rejects(bee.request('/stamps/1000000000/20', { method: 'POST', headers: { authorization: 'private token' } }), error => {
    assert.equal(error.code, 'BEE_HTTP_ERROR');
    assert.deepEqual(error.http, { status: 500, method: 'POST', path: '/stamps/1000000000/20' });
    assert.equal(JSON.stringify(error).includes('private'), false); return true;
  });
});
test('postage purchase waits for its exact batch to exist and become usable without buying twice', async () => {
  let purchases = 0, reads = 0;
  const states = [[], [{ batchID: batch, usable: false, exists: true }], [{ batchID: batch.toUpperCase(), usable: true, exists: true }]];
  const bee = createLocalBee({ endpoint: root, fetchImpl: async (url, init) => {
    if (init.method === 'POST') { purchases++; return response({ batchID: batch }); }
    assert.equal(url, root + '/stamps');
    return response({ stamps: [{ batchID: ref, usable: true, exists: true }, ...states[reads++]] });
  } });
  assert.equal(await bee.usableBatch(), batch); assert.equal(purchases, 1); assert.equal(reads, 3);
});
test('batch polling keeps HTTP failures visible and rejects ambiguous usability evidence', async () => {
  for (const listing of [null, { stamps: [{ batchID: batch, usable: true }] },
    { stamps: [{ batchID: batch, usable: true, exists: true }, { batchID: batch, usable: true, exists: true }] }]) {
    const bee = createLocalBee({ endpoint: root, fetchImpl: async (_, init) => init.method === 'POST'
      ? response({ batchID: batch }) : response(listing) });
    await assert.rejects(bee.usableBatch(), code('INVALID_BEE_RESPONSE'));
  }
  const failed = createLocalBee({ endpoint: root, fetchImpl: async (_, init) => init.method === 'POST'
    ? response({ batchID: batch }) : new Response('{}', { status: 400 }) });
  await assert.rejects(failed.usableBatch(), error => error.code === 'BEE_HTTP_ERROR' && error.http.status === 400 && error.http.path === '/stamps');
});
test('owned local site uploads retain a pinned copy before readback instead of depending on remote retrieval', async () => {
  const fixture=collectionTransport();let uploads=0;
  const bee=createLocalBee({endpoint:root,fetchImpl:async(url,options)=>{
    if(options.method==='POST'){
      uploads++;assert.equal(options.headers['swarm-pin'],'true');
      assert.equal(options.headers['swarm-deferred-upload'],'true');
      assert.equal(options.headers['swarm-postage-batch-id'],batch);
      assert.deepEqual(options.body,fixture.collection.tar);
    }
    return fixture.fetchImpl(url,options);
  }});
  const result=await bee.uploadSite(fixture.collection,batch);
  assert.equal(uploads,1);assert.equal(result.reference,ref);assert.equal(result.assetsVerified,fixture.collection.entries.length);
});
