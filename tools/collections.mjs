export class LocalDeliveryError extends Error {
  constructor(code) { super(code); this.name = 'LocalDeliveryError'; this.code = code; }
}
export const fail = code => { throw new LocalDeliveryError(code); };

// Deterministic POSIX ustar, zero timestamps/owners. Bee constructs the actual
// Swarm collection manifest from this tar; this tar's SHA is not its Swarm root.
export function createCollectionTar(entries) {
  if (!Array.isArray(entries) || !entries.length || entries.length > 64) fail('INVALID_COLLECTION');
  const seen = new Set(), parts = [];
  let total = 0;
  for (const entry of [...entries].sort((a, b) => a.name < b.name ? -1 : a.name > b.name ? 1 : 0)) {
    if (typeof entry.name !== 'string' || !/^[A-Za-z0-9_.-]+(?:\/[A-Za-z0-9_.-]+)*$/.test(entry.name)
        || entry.name.split('/').some(part => part === '.' || part === '..') || Buffer.byteLength(entry.name) > 100
        || seen.has(entry.name) || !(entry.bytes instanceof Uint8Array)) fail('INVALID_COLLECTION');
    seen.add(entry.name); total += entry.bytes.length;
    if (total > 16 * 1024 * 1024) fail('COLLECTION_SIZE_LIMIT');
    const header = Buffer.alloc(512);
    const field = (text, offset, length) => header.write(text, offset, length, 'ascii');
    const octal = (number, length) => number.toString(8).padStart(length - 1, '0') + '\0';
    field(entry.name, 0, 100); field(octal(0o644, 8), 100, 8);
    field(octal(0, 8), 108, 8); field(octal(0, 8), 116, 8);
    field(octal(entry.bytes.length, 12), 124, 12); field(octal(0, 12), 136, 12);
    header.fill(32, 148, 156); field('0', 156, 1); field('ustar\0', 257, 6); field('00', 263, 2);
    const checksum = header.reduce((sum, value) => sum + value, 0);
    field(checksum.toString(8).padStart(6, '0') + '\0 ', 148, 8);
    parts.push(header, Buffer.from(entry.bytes), Buffer.alloc((512 - entry.bytes.length % 512) % 512));
  }
  if (!seen.has('index.html')) fail('COLLECTION_INDEX_REQUIRED');
  parts.push(Buffer.alloc(1024));
  return Buffer.concat(parts);
}
