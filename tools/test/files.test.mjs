import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtemp, rm, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import {
  MAX_CHECKPOINT_FILE_BYTES, readBoundedFileBytes,
  writeExactCheckpointBytes, writeVerifiedCheckpointFile,
} from '../files.mjs';

async function workspace(t) {
  const directory = await mkdtemp(join(tmpdir(), 'swarm-file-test-'));
  t.after(() => rm(directory, { recursive: true, force: true }));
  return directory;
}

function payload(size = 1200000) {
  return Buffer.from(Array.from({ length: size }, (_, i) => i % 251));
}

// No implicit position exists: callers must supply every read/write position.
function shortHandle(capacity) {
  const disk = Buffer.alloc(capacity);
  const writes = [], reads = [];
  let size = 0, synced = false;
  return {
    disk, writes, reads,
    get synced() { return synced; },
    async write(bytes, offset, length, position) {
      assert.ok(Number.isSafeInteger(position));
      writes.push(position);
      const count = Math.min(length, 4093);
      bytes.copy(disk, position, offset, offset + count);
      size = Math.max(size, position + count);
      return { bytesWritten: count };
    },
    async read(bytes, offset, length, position) {
      assert.ok(Number.isSafeInteger(position));
      reads.push(position);
      const count = Math.min(length, 3079);
      disk.copy(bytes, offset, position, position + count);
      return { bytesRead: count };
    },
    async stat() { return { size }; },
    async sync() { synced = true; },
  };
}

test('bounded reads preserve multi-chunk JSON and Unicode exactly', async t => {
  const path = join(await workspace(t), 'unicode.json');
  const value = { state: 'ab'.repeat(700000), label: 'Biology — DNA 🧬' };
  await writeVerifiedCheckpointFile(path, JSON.stringify(value), { flag: 'wx' });
  assert.deepEqual(await readBoundedFileBytes(path), Buffer.from(JSON.stringify(value)));
});

test('bounded reads reject excessive size', async t => {
  const path = join(await workspace(t), 'bounded.json');
  await writeFile(path, '{"data":"synthetic"}');
  await assert.rejects(readBoundedFileBytes(path, 4), /CHECKPOINT_FILE_SIZE_LIMIT/);
});

test('read limits reject invalid bounds before I/O', async () => {
  for (const maximum of [0, -1, 1.5, NaN, Infinity, MAX_CHECKPOINT_FILE_BYTES + 1]) {
    await assert.rejects(readBoundedFileBytes('unused', maximum), /CHECKPOINT_FILE_LIMIT_INVALID/);
  }
});

test('verified multi-chunk writes preserve exclusive-create intent', async t => {
  const path = join(await workspace(t), 'exclusive.json');
  const value = { state: 'ab'.repeat(700000), label: 'DNA 🧬' };
  await writeVerifiedCheckpointFile(path, JSON.stringify(value), { flag: 'wx' });
  await assert.rejects(writeVerifiedCheckpointFile(path, '{}', { flag: 'wx' }), { code: 'EEXIST' });
  assert.deepEqual(await readBoundedFileBytes(path), Buffer.from(JSON.stringify(value)));
  await assert.rejects(writeVerifiedCheckpointFile(path, '{}', { flag: 'a' }), /CHECKPOINT_FILE_WRITE_FLAG/);
  assert.deepEqual(await readBoundedFileBytes(path), Buffer.from(JSON.stringify(value)));
});

test('explicit-position writes handle short writes and short verification reads', async () => {
  const bytes = payload(), handle = shortHandle(bytes.length);
  await writeExactCheckpointBytes(handle, bytes);
  assert.deepEqual(handle.disk, bytes);
  assert.ok(handle.writes.length > 2 && handle.reads.length > 2);
  assert.equal(handle.synced, true);
});

test('exact writes reject zero progress and corrupt readback', async () => {
  const bytes = Buffer.from('synthetic file');
  await assert.rejects(writeExactCheckpointBytes({ write: async () => ({ bytesWritten: 0 }) }, bytes),
    /CHECKPOINT_FILE_WRITE_INCOMPLETE/);
  await assert.rejects(writeExactCheckpointBytes({
    write: async (_bytes, _offset, length) => ({ bytesWritten: length }),
    stat: async () => ({ size: bytes.length }),
    read: async (buffer, _offset, length) => { buffer.fill(0); return { bytesRead: length }; },
    sync: async () => assert.fail('Corrupt readback must not be accepted'),
  }, bytes), /CHECKPOINT_FILE_WRITE_BYTES_MISMATCH/);
});
