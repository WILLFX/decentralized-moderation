import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtemp, mkdir, writeFile, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join, dirname } from 'node:path';
import { createHash } from 'node:crypto';
import { assets, assetsFor, collect, bindingsDirectory, root as workspace } from '../scripts/package.mjs';
import { resolve } from 'node:path';

test('generated bindings follow the selected Cargo target directory', () => {
  assert.equal(bindingsDirectory(''), join(workspace, 'target', 'web-bindings'));
  assert.equal(bindingsDirectory('external-target'), resolve('external-target', 'web-bindings'));
});

async function fixture(t, role = 'moderator') {
  const root = await mkdtemp(join(tmpdir(), 'swarm-rust-package-'));
  t.after(() => rm(root, { recursive: true, force: true }));
  const manifest = {};
  for (const name of assetsFor(role)) {
    const bytes = name.endsWith('.wasm') ? Buffer.from([0, 97, 115, 109, 1, 0, 0, 0]) : Buffer.from('public fixture');
    await mkdir(dirname(join(root, name)), { recursive: true });
    await writeFile(join(root, name), bytes);
    manifest[name] = createHash('sha256').update(bytes).digest('hex');
  }
  await writeFile(join(root, 'asset-hashes.json'), JSON.stringify(manifest));
  return { root, manifest };
}

test('fixed public collection has deterministic tar bytes', async t => {
  const { root } = await fixture(t);
  const one = await collect(root), two = await collect(root);
  assert.equal(one.entries.length, 7);
  assert.deepEqual(one.tar, two.tar);
});

test('a profile cannot be admitted by adding it to the manifest', async t => {
  const { root, manifest } = await fixture(t);
  await writeFile(join(root, 'profile.json'), '{}');
  manifest['profile.json'] = createHash('sha256').update('{}').digest('hex');
  await writeFile(join(root, 'asset-hashes.json'), JSON.stringify(manifest));
  await assert.rejects(collect(root), /PUBLIC_ASSET_ALLOWLIST_MISMATCH/);
});

test('changed assets fail closed', async t => {
  const { root } = await fixture(t);
  await writeFile(join(root, 'loader.js'), 'changed');
  await assert.rejects(collect(root), /ASSET_HASH_MISMATCH/);
});

test('hash-consistent invalid Wasm still fails', async t => {
  const { root, manifest } = await fixture(t);
  const name = 'pkg/swarm_moderator_bg.wasm', bytes = Buffer.from('bad wasm');
  await writeFile(join(root, name), bytes);
  manifest[name] = createHash('sha256').update(bytes).digest('hex');
  await writeFile(join(root, 'asset-hashes.json'), JSON.stringify(manifest));
  await assert.rejects(collect(root), /INVALID_WASM/);
});

for (const forbidden of ['encrypt_test', 'decrypt_test', 'encrypt_recovery_for_test',
  'decrypt_recovery_for_test', 'lifecyclevault_new', 'lifecyclevault_save', '__wbg_lifecyclevault_free']) {
  test(`test-only export ${forbidden} cannot enter the public collection`, async t => {
    const {root,manifest}=await fixture(t);
    const exportName=Buffer.from(forbidden);
    const bytes=Buffer.from([0,97,115,109,1,0,0,0,1,4,1,96,0,0,3,2,1,0,
      7,exportName.length+4,1,exportName.length,...exportName,0,0,10,4,1,2,0,11]);
    assert.equal(WebAssembly.validate(bytes),true);
    const name='pkg/swarm_moderator_bg.wasm';
    await writeFile(join(root,name),bytes);
    manifest[name]=createHash('sha256').update(bytes).digest('hex');
    await writeFile(join(root,'asset-hashes.json'),JSON.stringify(manifest));
    await assert.rejects(collect(root),/TEST_HARNESS_IN_PUBLIC_COLLECTION/);
  });
}

test('publisher and search collections remain separate fixed public packages', async t => {
  const publisher = await fixture(t, 'publisher');
  const search = await fixture(t, 'search');
  const pub = await collect(publisher.root, 'publisher');
  const found = await collect(search.root, 'search');
  assert.equal(pub.role, 'publisher-rust-preview');
  assert.equal(found.role, 'search-rust-preview');
  assert.ok(pub.entries.some(entry => entry.name === 'pkg/swarm_publisher_bg.wasm'));
  assert.ok(found.entries.some(entry => entry.name === 'pkg/swarm_search_bg.wasm'));
  assert.notDeepEqual(pub.tar, found.tar);
  await assert.rejects(collect(publisher.root, 'search'), /PUBLIC_ASSET_ALLOWLIST_MISMATCH/u);
  await assert.rejects(collect(search.root, '../publisher'), /INVALID_SITE_ROLE/u);
  assert.equal(bindingsDirectory('external-target', 'search'), resolve('external-target', 'web-bindings', 'search'));
});
