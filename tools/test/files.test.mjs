import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtemp, rm, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import {
  MAX_CHECKPOINT_FILE_BYTES, readBoundedFileBytes, readBoundedJsonFile,
  writeExactCheckpointBytes, writeVerifiedCheckpointFile,
  writeVerifiedByteStream, writeVerifiedByteStreamToHandle,
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

async function* chunks(bytes) {
  for (let offset = 0; offset < bytes.length; offset += 65539) {
    yield bytes.subarray(offset, offset + 65539);
  }
}

test('bounded reads preserve multi-chunk JSON and Unicode exactly', async t => {
  const path = join(await workspace(t), 'unicode.json');
  const value = { state: 'ab'.repeat(700000), label: 'Biology — DNA 🧬' };
  await writeVerifiedCheckpointFile(path, JSON.stringify(value), { flag: 'wx' });
  assert.deepEqual(await readBoundedJsonFile(path), value);
  assert.deepEqual(await readBoundedFileBytes(path), Buffer.from(JSON.stringify(value)));
});

test('bounded readers reject excessive size, empty JSON and malformed JSON', async t => {
  const path = join(await workspace(t), 'bounded.json');
  await writeFile(path, '{"data":"synthetic"}');
  await assert.rejects(readBoundedJsonFile(path, 4), /CHECKPOINT_FILE_SIZE_LIMIT/);
  await writeFile(path, '');
  await assert.rejects(readBoundedJsonFile(path), /CHECKPOINT_FILE_SIZE_LIMIT/);
  await writeFile(path, '{');
  await assert.rejects(readBoundedJsonFile(path), SyntaxError);
});

test('read and stream limits reject invalid bounds before I/O', async () => {
  for (const maximum of [0, -1, 1.5, NaN, Infinity, MAX_CHECKPOINT_FILE_BYTES + 1]) {
    await assert.rejects(readBoundedFileBytes('unused', maximum), /CHECKPOINT_FILE_LIMIT_INVALID/);
    await assert.rejects(writeVerifiedByteStreamToHandle({}, chunks(Buffer.from('x')), maximum),
      /CHECKPOINT_FILE_LIMIT_INVALID/);
  }
});

test('verified multi-chunk writes preserve exclusive-create intent', async t => {
  const path = join(await workspace(t), 'exclusive.json');
  const value = { state: 'ab'.repeat(700000), label: 'DNA 🧬' };
  await writeVerifiedCheckpointFile(path, JSON.stringify(value), { flag: 'wx' });
  await assert.rejects(writeVerifiedCheckpointFile(path, '{}', { flag: 'wx' }), { code: 'EEXIST' });
  assert.deepEqual(await readBoundedJsonFile(path), value);
  await assert.rejects(writeVerifiedCheckpointFile(path, '{}', { flag: 'a' }), /CHECKPOINT_FILE_WRITE_FLAG/);
  assert.deepEqual(await readBoundedJsonFile(path), value);
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

test('streamed transport verifies multi-chunk bytes with only explicit positions', async () => {
  const bytes = payload(), handle = shortHandle(bytes.length);
  assert.deepEqual(await writeVerifiedByteStreamToHandle(handle, chunks(bytes)), { bytes: bytes.length });
  assert.deepEqual(handle.disk, bytes);
  assert.ok(handle.writes.length > 2 && handle.reads.length > 2);
  assert.equal(handle.synced, true);
});

test('stream rejects changed readback bytes', async () => {
  const bytes = Buffer.from('synthetic stream'), handle = shortHandle(bytes.length);
  const read = handle.read.bind(handle);
  handle.read = async (...args) => {
    const result = await read(...args);
    args[0][args[1]] ^= 1;
    return result;
  };
  await assert.rejects(writeVerifiedByteStreamToHandle(handle, chunks(bytes)),
    /CHECKPOINT_FILE_WRITE_BYTES_MISMATCH/);
});

test('stream rejects an over-limit chunk before that chunk is written', async () => {
  const writes = [];
  const handle = { write: async (_bytes, _offset, length, position) => {
    writes.push([position, length]); return { bytesWritten: length };
  } };
  async function* source() { yield Buffer.alloc(4); yield Buffer.alloc(2); }
  await assert.rejects(writeVerifiedByteStreamToHandle(handle, source(), 5), /CHECKPOINT_FILE_SIZE_LIMIT/);
  assert.deepEqual(writes, [[0, 4]]);
});

test('stream rejects invalid progress instead of looping or accepting incomplete bytes', async () => {
  const bytes = Buffer.from('synthetic stream');
  for (const count of [0, -1, NaN, bytes.length + 1]) {
    await assert.rejects(writeVerifiedByteStreamToHandle({
      write: async () => ({ bytesWritten: count }),
    }, chunks(bytes)), /CHECKPOINT_FILE_WRITE_INCOMPLETE/);
    const handle = shortHandle(bytes.length);
    handle.read = async () => ({ bytesRead: count });
    await assert.rejects(writeVerifiedByteStreamToHandle(handle, chunks(bytes)),
      /CHECKPOINT_FILE_WRITE_INCOMPLETE/);
  }
});

test('stream rejects empty input and a final size mismatch', async () => {
  await assert.rejects(writeVerifiedByteStreamToHandle({}, chunks(Buffer.alloc(0))),
    /CHECKPOINT_FILE_WRITE_SIZE_MISMATCH/);
  const bytes = Buffer.from('synthetic stream'), handle = shortHandle(bytes.length);
  handle.stat = async () => ({ size: bytes.length - 1 });
  await assert.rejects(writeVerifiedByteStreamToHandle(handle, chunks(bytes)),
    /CHECKPOINT_FILE_WRITE_SIZE_MISMATCH/);
});

test('stream file wrapper preserves bytes and refuses an existing target', async t => {
  const path = join(await workspace(t), 'stream.bin'), bytes = payload();
  assert.deepEqual(await writeVerifiedByteStream(path, chunks(bytes)), { bytes: bytes.length });
  assert.deepEqual(await readBoundedFileBytes(path), bytes);
  await assert.rejects(writeVerifiedByteStream(path, chunks(Buffer.from('replacement'))), { code: 'EEXIST' });
  assert.deepEqual(await readBoundedFileBytes(path), bytes);
});
