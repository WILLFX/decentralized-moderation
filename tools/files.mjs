import { createHash } from 'node:crypto';
// Large checkpoint JSON must not be accumulated as UTF-8 strings by readFile.
// Read a fixed, bounded byte buffer, then decode exactly once.
import { open } from 'node:fs/promises';
import { constants as bufferConstants } from 'node:buffer';

export const MAX_CHECKPOINT_FILE_BYTES = 513 * 1024 * 1024;

export async function readBoundedFileBytes(path, maxBytes = MAX_CHECKPOINT_FILE_BYTES) {
  if (!Number.isSafeInteger(maxBytes) || maxBytes <= 0 || maxBytes > MAX_CHECKPOINT_FILE_BYTES)
    throw new Error('CHECKPOINT_FILE_LIMIT_INVALID');
  const file = await open(path, 'r');
  try {
    const before = await file.stat();
    if (!before.isFile() || !Number.isSafeInteger(before.size) || before.size < 0
      || before.size > maxBytes || before.size > bufferConstants.MAX_STRING_LENGTH)
      throw new Error('CHECKPOINT_FILE_SIZE_LIMIT');
    const bytes = Buffer.allocUnsafe(before.size);
    let offset = 0;
    while (offset < bytes.length) {
      const { bytesRead } = await file.read(bytes, offset, Math.min(512 * 1024, bytes.length - offset), offset);
      if (bytesRead === 0) throw new Error('CHECKPOINT_FILE_TRUNCATED');
      offset += bytesRead;
    }
    const after = await file.stat();
    if (before.size !== after.size || before.mtimeMs !== after.mtimeMs)
      throw new Error('CHECKPOINT_FILE_CHANGED_DURING_READ');
    return bytes;
  } finally { await file.close(); }
}


export async function readBoundedJsonFile(path, maxBytes = MAX_CHECKPOINT_FILE_BYTES) {
  const bytes = await readBoundedFileBytes(path, maxBytes);
  if (!bytes.length) throw new Error('CHECKPOINT_FILE_SIZE_LIMIT');
  return JSON.parse(bytes.toString('utf8'));
}

// Use explicit positions for every write and verify from disk. Some mounted
// filesystems/runtime combinations fail to advance an implicit file offset.
export async function writeExactCheckpointBytes(file, bytes) {
  let offset = 0;
  while (offset < bytes.length) {
    const length = Math.min(512 * 1024, bytes.length - offset);
    const { bytesWritten } = await file.write(bytes, offset, length, offset);
    if (!Number.isSafeInteger(bytesWritten) || bytesWritten < 1 || bytesWritten > length)
      throw new Error('CHECKPOINT_FILE_WRITE_INCOMPLETE');
    offset += bytesWritten;
  }
  if ((await file.stat()).size !== bytes.length) throw new Error('CHECKPOINT_FILE_WRITE_SIZE_MISMATCH');
  const chunk = Buffer.allocUnsafe(Math.min(512 * 1024, bytes.length));
  offset = 0;
  while (offset < bytes.length) {
    const length = Math.min(chunk.length, bytes.length - offset);
    const { bytesRead } = await file.read(chunk, 0, length, offset);
    if (bytesRead < 1 || bytesRead > length || !chunk.subarray(0, bytesRead).equals(bytes.subarray(offset, offset + bytesRead)))
      throw new Error('CHECKPOINT_FILE_WRITE_BYTES_MISMATCH');
    offset += bytesRead;
  }
  await file.sync();
}

export async function writeVerifiedCheckpointFile(path, value, { flag = 'w', mode = 0o600 } = {}) {
  const bytes = typeof value === 'string' ? Buffer.from(value, 'utf8') : value;
  if (!Buffer.isBuffer(bytes) || bytes.length < 1 || bytes.length > MAX_CHECKPOINT_FILE_BYTES)
    throw new Error('CHECKPOINT_FILE_SIZE_LIMIT');
  if (!['w', 'wx'].includes(flag)) throw new Error('CHECKPOINT_FILE_WRITE_FLAG');
  const file = await open(path, flag === 'wx' ? 'wx+' : 'w+', mode);
  try { await writeExactCheckpointBytes(file, bytes); }
  finally { await file.close(); }
}

// Transport raw bytes with bounded buffers and explicit positions. This does
// not parse chain state; the native Rust tool validates the finished RPC file.
export async function writeVerifiedByteStreamToHandle(file, source, maximum = MAX_CHECKPOINT_FILE_BYTES) {
  if (!Number.isSafeInteger(maximum) || maximum < 1 || maximum > MAX_CHECKPOINT_FILE_BYTES) throw new Error('CHECKPOINT_FILE_LIMIT_INVALID');
  const digest = createHash('sha256'); let position = 0;
  for await (const chunk of source) {
    if (!(chunk instanceof Uint8Array) || position + chunk.length > maximum) throw new Error('CHECKPOINT_FILE_SIZE_LIMIT');
    let offset = 0;
    while (offset < chunk.length) {
      const length = Math.min(512 * 1024, chunk.length - offset);
      const { bytesWritten } = await file.write(chunk, offset, length, position + offset);
      if (!Number.isSafeInteger(bytesWritten) || bytesWritten < 1 || bytesWritten > length) throw new Error('CHECKPOINT_FILE_WRITE_INCOMPLETE');
      offset += bytesWritten;
    }
    digest.update(chunk); position += chunk.length;
  }
  if (position < 1 || (await file.stat()).size !== position) throw new Error('CHECKPOINT_FILE_WRITE_SIZE_MISMATCH');
  await file.sync();
  const expected = digest.digest(); const actual = createHash('sha256');
  const buffer = Buffer.allocUnsafe(Math.min(512 * 1024, position)); let offset = 0;
  while (offset < position) {
    const length = Math.min(buffer.length, position - offset);
    const { bytesRead } = await file.read(buffer, 0, length, offset);
    if (!Number.isSafeInteger(bytesRead) || bytesRead < 1 || bytesRead > length) throw new Error('CHECKPOINT_FILE_WRITE_INCOMPLETE');
    actual.update(buffer.subarray(0, bytesRead)); offset += bytesRead;
  }
  if (!expected.equals(actual.digest())) throw new Error('CHECKPOINT_FILE_WRITE_BYTES_MISMATCH');
  return { bytes: position };
}
export async function writeVerifiedByteStream(path, source, maximum) {
  const file = await open(path, 'wx+', 0o600);
  try { return await writeVerifiedByteStreamToHandle(file, source, maximum); }
  finally { await file.close(); }
}

export const sameBytes = (a, b) => a.length === b.length && a.every((value, index) => value === b[index]);
