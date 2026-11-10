import { readBoundedFileBytes, writeVerifiedCheckpointFile } from '../../tools/files.mjs';
import { mkdir, readdir, lstat, unlink } from 'node:fs/promises';
import { resolve, join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';
import { createHash } from 'node:crypto';
import { gzipSync, gunzipSync } from 'node:zlib';
import { createCollectionTar } from '../../tools/collections.mjs';

export const root = resolve(dirname(fileURLToPath(import.meta.url)), '..');
export const roles = Object.freeze(['moderator', 'publisher', 'search']);
export function assetsFor(role = 'moderator') {
  if (!roles.includes(role)) throw new Error('INVALID_SITE_ROLE');
  return Object.freeze(['index.html', 'MODERATION_GUIDELINES.md',
    `swarm_${role}.js`, `swarm_${role}_bg.wasm.gz`]);
}
export const assets = assetsFor();
const hash = bytes => createHash('sha256').update(bytes).digest('hex');
const fail = code => { throw new Error(code); };
const maxAssetBytes = 8 * 1024 * 1024;
export function staticDirectory(role = 'moderator') {
  assetsFor(role);
  return join(root, 'apps', role, 'static');
}
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
  if (!stat.isFile() || stat.size > maxAssetBytes) fail('PUBLIC_ASSET_SIZE_LIMIT');
  const bytes = await readBoundedFileBytes(path, maxAssetBytes);
  if (bytes.length > maxAssetBytes) fail('PUBLIC_ASSET_SIZE_LIMIT');
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
  base ??= staticDirectory(role);
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
    if (name.endsWith('.wasm.gz')) {
      let wasm;
      try { wasm = gunzipSync(bytes, { maxOutputLength: maxAssetBytes }); }
      catch { fail('INVALID_WASM_GZIP'); }
      if (!WebAssembly.validate(wasm)) fail('INVALID_WASM');
      if (WebAssembly.Module.exports(new WebAssembly.Module(wasm)).some(item =>
        /^(?:(?:encrypt_test|decrypt_test|encrypt_recovery_for_test|decrypt_recovery_for_test)$|(?:__wbg_)?lifecyclevault(?:_|$))/u.test(item.name))) {
        fail('TEST_HARNESS_IN_PUBLIC_COLLECTION');
      }
    }
    entries.push({ name, bytes, sha256: hash(bytes) });
  }
  entries.push({ name: 'asset-hashes.json', bytes: rawManifest, sha256: hash(rawManifest) });
  return { role: `${role}-rust-preview`, entries, tar: createCollectionTar(entries) };
}

// Keep editable source files separate; ship their exact contents inline under CSP hashes.
export function renderPage(role, { html, css, bootstrap, view }) {
  assetsFor(role);
  for (const value of [html, css, bootstrap]) if (typeof value !== 'string') fail('INVALID_PAGE_SOURCE');
  html = html.replace(/\r\n?/g, '\n');
  css = css.replace(/\r\n?/g, '\n');
  bootstrap = bootstrap.replace(/\r\n?/g, '\n');
  if (/<\/style/i.test(css) || /<\/script/i.test(bootstrap)) fail('UNSAFE_INLINE_SOURCE');
  const styleMarker = '<link rel="stylesheet" href="./style.css">';
  const scriptMarker = '<script type="module" src="./loader.js"></script>';
  if (html.split(styleMarker).length !== 2 || html.split(scriptMarker).length !== 2) fail('PAGE_ENTRY_MISMATCH');
  if (role !== 'search') {
    if (typeof view !== 'string' || !html.includes('<main id="app">')) fail('PAGE_SHELL_MISSING');
    html = html.replace(/<main id="app">[\s\S]*?<\/main>/,
      () => `<main id="app">${view.replace(/\r\n?/g, '\n')}</main>`);
  }
  html = html.replace(/\s*<p id="boot"[^>]*>[\s\S]*?<\/p>/, '');
  // Rust decides whether saved-history attention is needed after it reads storage.
  if (role === 'publisher') html = html.replace('<p id="history-attention"', '<p hidden id="history-attention"');
  const label = {search:'Swarm Search',publisher:'Swarm Publish',moderator:'Swarm Review'}[role];
  html = html.replace(/<main([^>]*)>/, (_, attributes) =>
    `<p id="boot" role="status">Starting ${label}…</p><button id="boot-retry" type="button" hidden>Reload</button><main${attributes} inert aria-busy="true">`);
  html = html.replace(styleMarker, () => `<style id="app-style">${css}</style>`)
    .replace(scriptMarker, () => `<script id="app-bootstrap" type="module">${bootstrap}</script>`);
  const policy = html.match(/<meta http-equiv="Content-Security-Policy" content="([^"]+)">/);
  if (!policy || !policy[1].includes("script-src 'self' 'wasm-unsafe-eval'") || !policy[1].includes("style-src 'self'")) fail('PAGE_CSP_MISSING');
  const digest = value => `'sha256-${createHash('sha256').update(value).digest('base64')}'`;
  const csp = policy[1].replace("script-src 'self' 'wasm-unsafe-eval'", `script-src 'self' 'wasm-unsafe-eval' ${digest(bootstrap)}`)
    .replace("style-src 'self'", `style-src 'self' ${digest(css)}`);
  return Buffer.from(html.replace(policy[0], `<meta http-equiv="Content-Security-Policy" content="${csp}">`));
}

export async function packagePreview(role = 'moderator') {
  const assets = assetsFor(role);
  const destination = staticDirectory(role);
  await mkdir(destination, { recursive: true });
  const source = join(root, 'apps', role);
  const html = await renderPage(role, {
    html: (await safeRead(source, 'index.html')).toString('utf8'),
    css: (await safeRead(source, 'style.css')).toString('utf8'),
    bootstrap: (await safeRead(source, 'loader.js')).toString('utf8'),
    view: role === 'search' ? undefined : (await safeRead(join(root, 'crates', 'swarm-browser', 'src', role), 'view.html')).toString('utf8'),
  });
  const manifest = {};
  const bindings = bindingsDirectory(process.env.CARGO_TARGET_DIR, role);
  for (const name of assets) {
    let bytes;
    if (name === 'index.html') bytes = html;
    else if (name.endsWith('.wasm.gz')) bytes = gzipSync(await safeRead(bindings, name.slice(0, -3)), { level: 9 });
    else bytes = await safeRead(name.endsWith('.js') ? bindings : source, name);
    await writeVerifiedCheckpointFile(join(destination, name), bytes);
    manifest[name] = hash(bytes);
  }
  await writeVerifiedCheckpointFile(join(destination, 'asset-hashes.json'), JSON.stringify(manifest, null, 2) + '\n');
  // Migrate an existing generated folder without removing unrelated files.
  const legacyWasm = join(destination, `swarm_${role}_bg.wasm`);
  const legacy = await lstat(legacyWasm).catch(error => {
    if (error.code !== 'ENOENT') throw error;
  });
  if (legacy) {
    if (!legacy.isFile()) fail('UNSAFE_PUBLIC_ASSET');
    await unlink(legacyWasm);
  }
  const collection = await collect(destination, role);
  console.log(`Packaged ${collection.entries.length} public assets; Wasm validates. No profile or recovery file is included.`);
}

if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  const args = process.argv.slice(2);
  (args.length > 1 ? Promise.reject(new Error('ONE_SITE_ROLE_REQUIRED')) : packagePreview(args[0] ?? 'moderator'))
    .catch(error => { console.error(error.message); process.exitCode = 1; });
}
