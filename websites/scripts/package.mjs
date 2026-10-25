import { readBoundedFileBytes, writeVerifiedCheckpointFile } from '../../tools/files.mjs';
import { mkdir, readdir, lstat } from 'node:fs/promises';
import { resolve, join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';
import { createHash } from 'node:crypto';
import { createCollectionTar } from '../../tools/collections.mjs';

export const root = resolve(dirname(fileURLToPath(import.meta.url)), '..');
export const roles = Object.freeze(['moderator', 'publisher', 'search']);
export function assetsFor(role = 'moderator') {
  if (!roles.includes(role)) throw new Error('INVALID_SITE_ROLE');
  return Object.freeze(['index.html', 'loader.js', 'style.css',
    'MODERATION_GUIDELINES.md', `pkg/swarm_${role}.js`, `pkg/swarm_${role}_bg.wasm`]);
}
export const assets = assetsFor();
const hash = bytes => createHash('sha256').update(bytes).digest('hex');
const fail = code => { throw new Error(code); };
export const bindingsDirectory = (target, role = 'moderator') => {
  assetsFor(role);
  return role === 'moderator' ? resolve(target || join(root, 'target'), 'web-bindings')
    : resolve(target || join(root, 'target'), 'web-bindings', role);
};

async function safeRead(base, name) {
  let path = base;
  for (const segment of name.split('/')) {
    path = join(path, segment);
    if ((await lstat(path)).isSymbolicLink()) fail('UNSAFE_PUBLIC_ASSET');
  }
  const stat = await lstat(path);
  if (!stat.isFile() || stat.size > 8 * 1024 * 1024) fail('PUBLIC_ASSET_SIZE_LIMIT');
  const bytes = await readBoundedFileBytes(path, 8 * 1024 * 1024);
  if (bytes.length > 8 * 1024 * 1024) fail('PUBLIC_ASSET_SIZE_LIMIT');
  return bytes;
}

async function walk(base, prefix = '') {
  const names = [];
  for (const item of await readdir(join(base, prefix), { withFileTypes: true })) {
    if (item.isSymbolicLink()) fail('UNSAFE_PUBLIC_ASSET');
    const name = prefix + item.name;
    if (item.isDirectory()) names.push(...await walk(base, name + '/'));
    else if (item.isFile()) names.push(name);
    else fail('UNSAFE_PUBLIC_ASSET');
  }
  return names.sort();
}

export async function collect(base, role = 'moderator') {
  const assets = assetsFor(role);
  base ??= join(root, 'dist', role);
  const stat = await lstat(base);
  if (stat.isSymbolicLink() || !stat.isDirectory()) fail('UNSAFE_PUBLIC_ASSET');
  const expected = [...assets, 'asset-hashes.json'].sort();
  if (JSON.stringify(await walk(base)) !== JSON.stringify(expected)) fail('PUBLIC_ASSET_ALLOWLIST_MISMATCH');
  const rawManifest = await safeRead(base, 'asset-hashes.json');
  if (rawManifest.length > 4096) fail('INVALID_MANIFEST');
  const manifest = JSON.parse(rawManifest.toString('utf8'));
  if (!manifest || Array.isArray(manifest) || JSON.stringify(Object.keys(manifest).sort()) !== JSON.stringify([...assets].sort())) fail('INVALID_MANIFEST');
  const entries = [];
  let total = 0;
  for (const name of assets) {
    const bytes = await safeRead(base, name);
    if (hash(bytes) !== manifest[name]) fail('ASSET_HASH_MISMATCH');
    total += bytes.length;
    if (total > 16 * 1024 * 1024) fail('PUBLIC_COLLECTION_SIZE_LIMIT');
    if (name.endsWith('.wasm')) {
      if (!WebAssembly.validate(bytes)) fail('INVALID_WASM');
      if (WebAssembly.Module.exports(new WebAssembly.Module(bytes)).some(item =>
        /^(?:(?:encrypt_test|decrypt_test|encrypt_recovery_for_test|decrypt_recovery_for_test)$|(?:__wbg_)?lifecyclevault(?:_|$))/u.test(item.name))) {
        fail('TEST_HARNESS_IN_PUBLIC_COLLECTION');
      }
    }
    entries.push({ name, bytes, sha256: hash(bytes) });
  }
  entries.push({ name: 'asset-hashes.json', bytes: rawManifest, sha256: hash(rawManifest) });
  return { role: `${role}-rust-preview`, entries, tar: createCollectionTar(entries) };
}

export async function packagePreview(role = 'moderator') {
  const assets = assetsFor(role);
  const destination = join(root, 'dist', role);
  await mkdir(join(destination, 'pkg'), { recursive: true });
  const manifest = {};
  for (const name of assets) {
    const source = name.startsWith('pkg/') ? bindingsDirectory(process.env.CARGO_TARGET_DIR, role) : join(root, 'apps', role);
    const sourceName = name.startsWith('pkg/') ? name.slice(4) : name;
    const bytes = await safeRead(source, sourceName);
    await writeVerifiedCheckpointFile(join(destination, name), bytes);
    manifest[name] = hash(bytes);
  }
  await writeVerifiedCheckpointFile(join(destination, 'asset-hashes.json'), JSON.stringify(manifest, null, 2) + '\n');
  const collection = await collect(destination, role);
  console.log(`Packaged ${collection.entries.length} public assets; Wasm validates. No profile or recovery file is included.`);
}

if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  const args = process.argv.slice(2);
  (args.length > 1 ? Promise.reject(new Error('ONE_SITE_ROLE_REQUIRED')) : packagePreview(args[0] ?? 'moderator'))
    .catch(error => { console.error(error.message); process.exitCode = 1; });
}
