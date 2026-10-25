import test from 'node:test';
import assert from 'node:assert/strict';
import { verifyFactoryMetadata, verifyFactoryArchive, BEE_FACTORY_VERSION, BEE_FACTORY_INTEGRITY, BEE_FACTORY_ARCHIVE_URL, factoryArchivePath } from './storage-artifact.mjs';
const metadata = () => ({ name: '@ethersphere/bee-factory', version: BEE_FACTORY_VERSION,
  dist: { integrity: BEE_FACTORY_INTEGRITY, tarball: BEE_FACTORY_ARCHIVE_URL, factoryArchivePath } });
test('only the pinned storage package metadata is admitted', () => {
  assert.doesNotThrow(() => verifyFactoryMetadata(metadata()));
});
for (const [name, change] of [
  ['a different release', m => { m.version = '1.1.3'; }],
  ['a substituted integrity', m => { m.dist.integrity = 'sha512-foreign'; }],
  ['an alternate download host', m => { m.dist.tarball = 'https://example.com/bee-factory-1.1.2.tgz'; }],
  ['an unrelated package', m => { m.name = 'other'; }],
]) test('rejects ' + name + ' before archive download', () => {
  const m = metadata(); change(m); assert.throws(() => verifyFactoryMetadata(m), /INVALID_UPSTREAM_METADATA/);
});
test('archive bytes must independently match the pin, even with matching metadata', () => {
  verifyFactoryMetadata(metadata());
  assert.throws(() => verifyFactoryArchive(Buffer.from('substituted archive')), /FACTORY_PACKAGE_INTEGRITY_FAILED/);
});

import { mkdtemp, mkdir, writeFile, readFile, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join, dirname } from 'node:path';
test('nested saved runs still read the archive created in the session-root cache', async t => {
  const sessionRoot = await mkdtemp(join(tmpdir(), 'swarm-artifact-path-'));
  t.after(() => rm(sessionRoot, { recursive: true, force: true }));
  const nestedRun = join(sessionRoot, 'runs', 'owned-run');
  await mkdir(nestedRun, { recursive: true });
  const downloadPath = factoryArchivePath(sessionRoot);
  await mkdir(dirname(downloadPath), { recursive: true });
  await writeFile(downloadPath, 'path-fixture');
  const resumePath = factoryArchivePath(sessionRoot);
  assert.equal(await readFile(resumePath, 'utf8'), 'path-fixture');
  assert.notEqual(resumePath, join(nestedRun, '..', 'preflight', 'bee-factory-1.1.2.tgz'));
});
test('relative or URL-valued session roots cannot select an artifact path', () => {
  for (const root of ['', 'relative/session', 'https://example.com', null])
    assert.throws(() => factoryArchivePath(root), /ABSOLUTE_SESSION_ROOT_REQUIRED/);
});
