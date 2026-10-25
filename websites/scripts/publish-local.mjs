import { readBoundedFileBytes } from '../../tools/files.mjs';
// Additive preview upload to the already-owned LOCAL Bee session only.
import assert from 'node:assert/strict';
import { mkdir, writeFile } from 'node:fs/promises';
import { join, resolve, relative, isAbsolute } from 'node:path';
import { fileURLToPath } from 'node:url';
import { createHash } from 'node:crypto';
import { collect, root, assetsFor } from './package.mjs';
import { createLocalBee, localEndpoint, readUploadedAsset } from '../../tools/local-bee/bee.mjs';
import { docker, inspectOwnedRelay, inspectOwnedContainer, OWNER_LABEL, IMAGES, validRunId } from '../../tools/local-bee/docker.mjs';

const delivery = process.env.LOCAL_BEE_SESSION_ROOT
  ? resolve(process.env.LOCAL_BEE_SESSION_ROOT)
  : resolve(root, '../tools/local-session');
const sha = bytes => createHash('sha256').update(bytes).digest('hex');
let stage = 'Reading current local session and public collection';
const jsonFile = async path => {
  const bytes = await readBoundedFileBytes(path, 512 * 1024);
  assert.ok(bytes.length <= 512 * 1024, 'LOCAL_RECORD_TOO_LARGE');
  return JSON.parse(bytes.toString('utf8'));
};

export function sessionPaths(session, base) {
  assert.equal(session?.status, 'running', 'LOCAL_SESSION_NOT_RUNNING');
  assert.equal(localEndpoint(session.home), 'http://127.0.0.1:51280', 'LOCAL_SESSION_HOME_MISMATCH');
  assert.equal(localEndpoint(session.rpc), 'http://127.0.0.1:51282', 'LOCAL_SESSION_RPC_MISMATCH');
  const inside = (parent, child) => {
    const rel = relative(parent, child);
    return rel !== '' && !isAbsolute(rel) && rel !== '..' && !rel.startsWith('..' + (process.platform === 'win32' ? '\\' : '/'));
  };
  assert.equal(typeof session.sourceRun, 'string', 'INVALID_LOCAL_RUN');
  assert.equal(typeof session.recovery, 'string', 'INVALID_LOCAL_RECOVERY');
  const run = resolve(session.sourceRun), recovery = resolve(session.recovery);
  assert.ok(inside(resolve(base), run) && inside(run, recovery), 'LOCAL_RECOVERY_OUTSIDE_DELIVERY');
  return { recovery, environment: join(recovery, 'environment/environment.json') };
}

export async function proveEnvironment(state) {
  assert.equal(state.kind, 'isolated-local-bee-environment');
  validRunId(state.runId);
  assert.equal(state.storageChainId, '1337');
  assert.equal(state.bees?.length, 5);
  for (const name of ['bee', 'anvil', 'relay']) assert.equal(state.images[name].requested, IMAGES[name]);
  for (const [id, internal] of [[state.networkId, true], [state.accessNetworkId, false]]) {
    assert.match(id, /^[0-9a-f]{64}$/u);
    const network = JSON.parse(await docker(['network', 'inspect', id]))[0];
    assert.equal(network.Internal, internal);
    assert.equal(network.Labels?.[OWNER_LABEL], state.runId);
  }
  const inspect = async id => {
    assert.match(id, /^[0-9a-f]{64}$/u);
    return JSON.parse(await docker(['inspect', id]))[0];
  };
  const endpoints = inspectOwnedRelay(await inspect(state.relayId), {
    runId: state.runId, networkId: state.networkId,
    accessNetworkId: state.accessNetworkId, imageId: state.images.relay.id,
  });
  inspectOwnedContainer(await inspect(state.storageId), { runId: state.runId,
    networkId: state.networkId, imageId: state.images.anvil.id });
  for (let i = 0; i < state.bees.length; i++) {
    inspectOwnedContainer(await inspect(state.bees[i].id), { runId: state.runId,
      networkId: state.networkId, imageId: state.images.bee.id });
    assert.equal(localEndpoint(state.bees[i].endpoint), endpoints[1633 + i]);
  }
  assert.equal(localEndpoint(state.storageEndpoint), endpoints[8545]);
  const chain = await createLocalBee({ endpoint: endpoints[8545], timeoutMs: 15000 }).json('/', {
    method: 'POST', headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ jsonrpc: '2.0', id: 1, method: 'eth_chainId', params: [] }),
  });
  assert.equal(chain.jsonrpc, '2.0'); assert.equal(chain.id, 1);
  assert.equal(chain.result, '0x539'); assert.equal(chain.error, undefined);
  return endpoints[1633];
}

export async function verifyPublicRoundTrip(bee, collection, reference) {
  assert.match(reference, /^[0-9a-f]{64}$/u);
  const types = name => name.endsWith('.wasm') ? /^application\/wasm(?:;|$)/iu
    : name.endsWith('.js') ? /^(?:text|application)\/javascript(?:;|$)/iu
    : name.endsWith('.css') ? /^text\/css(?:;|$)/iu
    : name.endsWith('.html') ? /^text\/html(?:;|$)/iu : null;
  for (const entry of collection.entries) {
    const found = await readUploadedAsset(bee.request, `/bzz/${reference}/${entry.name}`);
    assert.deepEqual(found.bytes, Buffer.from(entry.bytes), 'PUBLIC_ASSET_ROUND_TRIP_MISMATCH');
    const mime = types(entry.name);
    if (mime) assert.match(found.type, mime, 'PUBLIC_ASSET_MEDIA_TYPE_MISMATCH');
  }
}

async function main() {
  const args = process.argv.slice(2);
  assert.ok(args.length <= 1, 'ONE_SITE_ROLE_REQUIRED');
  const role = args[0] ?? 'moderator';
  assetsFor(role);
  assert.equal(process.platform, 'linux', 'RUN_IN_UBUNTU_WITH_THE_OWNED_DOCKER_SESSION');
  const sessionFile = join(delivery, 'current/session.json');
  const session = await jsonFile(sessionFile);
  const paths = sessionPaths(session, delivery);
  const environment = await jsonFile(paths.environment);
  const collection = await collect(join(root, 'dist', role), role);
  console.log('Checking ownership of the existing local Bee environment.');
  stage = 'Proving ownership of the running local Bee and storage chain';
  const endpoint = await proveEnvironment(environment);
  stage = 'Checking the current served publisher profile';
  const profile = await jsonFile(join(delivery, 'current/publisher-local-bee-profile.json'));
  assert.equal(localEndpoint(profile.upload.endpoint), localEndpoint(session.home));
  assert.match(profile.upload.postageBatchId, /^[0-9a-f]{64}$/u);
  const front = createLocalBee({ endpoint: session.home });
  const servedProfile = await front.json('/__local/profile/publisher.json');
  assert.deepEqual(servedProfile, profile, 'LOCAL_PROFILE_IS_STALE');
  assert.deepEqual(await jsonFile(sessionFile), session, 'LOCAL_SESSION_CHANGED');
  const bee = createLocalBee({ endpoint });
  stage = 'Checking existing local postage usability';
  const listing = await bee.json('/stamps');
  assert.ok(Array.isArray(listing.stamps) && listing.stamps.length <= 4096);
  const matches = listing.stamps.filter(s => typeof s.batchID === 'string'
    && s.batchID.toLowerCase() === profile.upload.postageBatchId);
  assert.equal(matches.length, 1, 'LOCAL_POSTAGE_NOT_UNIQUE');
  const stamp = matches[0];
  assert.equal(stamp.usable, true, 'LOCAL_POSTAGE_NOT_USABLE');
  assert.equal(stamp.exists, true, 'LOCAL_POSTAGE_NOT_PRESENT');
  console.log(`Uploading only the ${collection.entries.length} public Rust ${role} assets to the owned local Bee.`);
  stage = 'Uploading and reading back the public Rust collection through the owned Bee';
  const uploaded = await bee.uploadSite(collection, profile.upload.postageBatchId, { onProgress: console.log });
  stage = 'Verifying public front-door bytes and HTML/JavaScript/CSS/Wasm media types';
  await verifyPublicRoundTrip(front, collection, uploaded.reference);
  assert.deepEqual(await jsonFile(sessionFile), session, 'LOCAL_SESSION_CHANGED_AFTER_UPLOAD');
  const receipt = { kind: `local-rust-${role}-preview-publication`, at: new Date().toISOString(),
    recovery: paths.recovery, collectionTarSha256: sha(collection.tar), reference: uploaded.reference,
    url: `${localEndpoint(session.home)}/bzz/${uploaded.reference}/`,
    assets: collection.entries.map(e => ({ name: e.name, bytes: e.bytes.length, sha256: e.sha256 })),
    publicRoundTripVerified: true, wasmMediaTypeVerified: true,
    scope: 'New local collection only; original sites and moderation chain unchanged. Browser/MetaMask test pending.' };
  stage = 'Saving the local publication receipt';
  await mkdir(join(root, 'receipts'), { recursive: true });
  await writeFile(join(root, 'receipts', role === 'moderator' ? 'local-publication.json' : `local-${role}-publication.json`), JSON.stringify(receipt, null, 2) + '\n');
  console.log(`RUST PREVIEW PUBLISHED AND BYTE/MIME VERIFIED: ${receipt.url}`);
  console.log(role === 'search' ? 'Load the CURRENT search profile and verify deployment before searching.' : `Use the MetaMask-enabled browser. Load the CURRENT ${role} profile, then connect and verify deployment.`);
  console.log(`Current profile: ${join(delivery, 'current', `${role}-local-bee-profile.json`)}`);
}

if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  main().catch(error => {
    console.error(`Local Rust preview publication stopped: ${error.code ?? 'LOCAL_PREVIEW_CHECK_FAILED'}; stage: ${stage}.`);
    // Keep provider response bodies, headers and credential-bearing paths out of logs.
    process.exitCode = 1;
  });
}
