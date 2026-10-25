import { fail, LocalDeliveryError } from '../collections.mjs';
import { sameBytes } from '../files.mjs';

export function localEndpoint(value) {
  if (typeof value !== 'string' || value.length > 1024 || /[\u0000-\u0020\u007f?#\\]/u.test(value)) fail('LOCAL_ENDPOINT_REQUIRED');
  let url;
  try { url = new URL(value); } catch { fail('LOCAL_ENDPOINT_REQUIRED'); }
  if (typeof value !== 'string' || /[\u0000-\u0020\u007f?#\\]/u.test(value)
      || url.protocol !== 'http:' || !['127.0.0.1', 'localhost', '[::1]'].includes(url.hostname)
      || url.username || url.password || url.pathname !== '/' || !url.port) fail('LOCAL_ENDPOINT_REQUIRED');
  return url.origin;
}
const reference = value => {
  if (typeof value !== 'string' || value.length !== 64 || !/^[0-9a-f]{64}$/iu.test(value) || /^0+$/u.test(value)) fail('INVALID_BEE_REFERENCE');
  return value.toLowerCase();
};
export async function readUploadedAsset(read, path, { onRetry = () => {}, wait = ms => new Promise(done => setTimeout(done, ms)) } = {}) {
  for (let attempt = 1; attempt <= 3; attempt++) {
    try { return await read(path); }
    catch (error) {
      // Narrow read-after-write retry only. Never repeat the upload or excuse
      // wrong bytes/MIME, arbitrary HTTP failures or unrelated missing content.
      if (attempt === 3 || error.code !== 'BEE_HTTP_ERROR' || error.http?.status !== 404
          || error.http.method !== 'GET' || error.http.path !== path) throw error;
      onRetry({ path, attempt }); await wait(attempt * 1000);
    }
  }
}
export function createLocalBee({ endpoint, fetchImpl = globalThis.fetch, timeoutMs = 120000 } = {}) {
  const base = localEndpoint(endpoint);
  if (typeof fetchImpl !== 'function' || !Number.isSafeInteger(timeoutMs) || timeoutMs < 1 || timeoutMs > 300000) fail('INVALID_BEE_OPTIONS');
  async function request(path, options = {}, maximum = 20 * 1024 * 1024) {
    if (typeof path !== 'string' || !/^\/[A-Za-z0-9._~/-]*(?:\?[A-Za-z0-9._~=&%-]*)?$/u.test(path)
        || path.startsWith('//') || path.split('?')[0].split('/').some(part => part === '..')
        || !Number.isSafeInteger(maximum) || maximum < 1 || maximum > 20 * 1024 * 1024) fail('INVALID_BEE_REQUEST');
    const controller = new AbortController();
    let timer, reader;
    const operation = async () => {
      const response = await fetchImpl(base + path, { ...options, signal: controller.signal,
        redirect: 'error', credentials: 'omit', referrerPolicy: 'no-referrer', cache: 'no-store' });
      if (response.redirected || (response.url && response.url !== base + path)) fail('BEE_REDIRECT_REJECTED');
      if (!response.ok) {
        const error = new LocalDeliveryError('BEE_HTTP_ERROR');
        error.http = { status: response.status, method: options.method ?? 'GET', path };
        // Do not include credentials, headers or arbitrary upstream response
        // text. Bounded owned-node logs supply the detailed failure evidence.
        throw error;
      }
      const length = response.headers.get('content-length');
      if (length !== null && (!/^[0-9]+$/u.test(length) || !Number.isSafeInteger(Number(length)) || Number(length) > maximum)) fail('BEE_RESPONSE_SIZE_LIMIT');
      if (!response.body?.getReader) fail('INVALID_BEE_RESPONSE');
      reader = response.body.getReader(); const chunks = []; let size = 0;
      while (true) {
        const { done, value } = await reader.read();
        if (done) break;
        if (!(value instanceof Uint8Array)) fail('INVALID_BEE_RESPONSE');
        size += value.length;
        if (size > maximum) fail('BEE_RESPONSE_SIZE_LIMIT');
        chunks.push(Buffer.from(value));
      }
      const bytes = Buffer.concat(chunks);
      const encoding = response.headers.get('content-encoding');
      if (length !== null && (!encoding || encoding === 'identity') && Number(length) !== bytes.length) fail('BEE_TRUNCATED_RESPONSE');
      return { bytes, status: response.status, type: response.headers.get('content-type') ?? '' };
    };
    try {
      return await Promise.race([operation(), new Promise((_, reject) => {
        timer = setTimeout(() => { controller.abort(); reject(new Error('BEE_TIMEOUT')); }, timeoutMs);
      })]);
    } catch (error) {
      if (error instanceof LocalDeliveryError) throw error;
      fail(error?.message === 'BEE_TIMEOUT' ? 'BEE_TIMEOUT' : 'BEE_ACCESS_FAILED');
    } finally {
      clearTimeout(timer); controller.abort();
      try { Promise.resolve(reader?.cancel()).catch(() => {}); } catch { /* Do not wait on a failed source. */ }
    }
  }
  const json = async (path, options) => {
    const response = await request(path, options, 512 * 1024);
    try { return JSON.parse(new TextDecoder('utf-8', { fatal: true }).decode(response.bytes)); }
    catch { fail('INVALID_BEE_RESPONSE'); }
  };
  const uploadHeaders = batch => ({ 'swarm-postage-batch-id': reference(batch),
    'swarm-encrypt': 'false', 'swarm-act': 'false', 'swarm-redundancy-level': '0',
    // The isolated test node retains its own copy while its pusher propagates it.
    // An upload acknowledgement is not a replication/persistence claim.
    'swarm-pin': 'true', 'swarm-deferred-upload': 'true' });
  async function uploadBytes(bytes, batch) {
    if (!(bytes instanceof Uint8Array) || bytes.length > 1024 * 1024) fail('INVALID_LOCAL_CONTENT');
    const result = await json('/bytes', { method: 'POST', headers: { ...uploadHeaders(batch), 'Content-Type': 'application/octet-stream' }, body: bytes.slice() });
    return reference(result.reference);
  }
  async function uploadSite(collection, batch, { onProgress = () => {} } = {}) {
    if (!collection || !(collection.tar instanceof Uint8Array) || collection.tar.length > 17 * 1024 * 1024
        || !Array.isArray(collection.entries) || collection.entries.length < 1 || collection.entries.length > 64
        || collection.entries.some(entry => typeof entry.name !== 'string' || !/^[A-Za-z0-9_.-]+(?:\/[A-Za-z0-9_.-]+)*$/u.test(entry.name)
          || entry.name.split('/').some(part => part === '.' || part === '..') || !(entry.bytes instanceof Uint8Array))) fail('INVALID_COLLECTION');
    const result = await json('/bzz', { method: 'POST', headers: { ...uploadHeaders(batch),
      'Content-Type': 'application/x-tar', 'swarm-collection': 'true', 'swarm-index-document': 'index.html' }, body: collection.tar });
    const root = reference(result.reference);
    const index = collection.entries.find(entry => entry.name === 'index.html');
    const readBack = path => readUploadedAsset(request, path, {
      onRetry: ({ path, attempt }) => onProgress(`Bee upload readback returned 404; retry ${attempt}/2: ${path}`) });
    const rootPage = await readBack(`/bzz/${root}/`);
    if (!index || !sameBytes(rootPage.bytes, index.bytes) || !/^text\/html(?:;|$)/iu.test(rootPage.type)) fail('BEE_SITE_INDEX_MISMATCH');
    for (const entry of collection.entries) {
      const found = await readBack(`/bzz/${root}/${entry.name}`);
      if (!sameBytes(found.bytes, entry.bytes)) fail('BEE_SITE_ASSET_MISMATCH');
      if (/\.m?js$/u.test(entry.name) && !/^(?:text|application)\/javascript(?:;|$)/iu.test(found.type)) fail('BEE_SCRIPT_MEDIA_TYPE');
      if (entry.name.endsWith('.css') && !/^text\/css(?:;|$)/iu.test(found.type)) fail('BEE_STYLE_MEDIA_TYPE');
    }
    return { role: collection.role, reference: root, url: `${base}/bzz/${root}/`, assetsVerified: collection.entries.length };
  }
  async function usableBatch({ amount = '1000000000', depth = 20 } = {}) {
    if (amount !== '1000000000' || depth !== 20) fail('LOCAL_BATCH_PARAMETERS_REQUIRED');
    const result = await json(`/stamps/${amount}/${depth}?label=moderation-local-integration`, { method: 'POST' });
    const batch = reference(result.batchID);
    const expires = Date.now() + 180000;
    while (Date.now() < expires) {
      // The purchase can confirm before Bee can return an individual issuer.
      // The owner batch list exposes that waiting state through usable=false
      // (or an absent row). Do not treat an arbitrary HTTP 400 as retryable.
      const listing = await json('/stamps');
      if (!Array.isArray(listing?.stamps) || listing.stamps.length > 4096) fail('INVALID_BEE_RESPONSE');
      const matches = listing.stamps.filter(stamp => typeof stamp?.batchID === 'string' && stamp.batchID.toLowerCase() === batch);
      if (matches.length > 1) fail('INVALID_BEE_RESPONSE');
      const stamp = matches[0];
      if (stamp && (typeof stamp.usable !== 'boolean' || typeof stamp.exists !== 'boolean')) fail('INVALID_BEE_RESPONSE');
      if (stamp?.usable === true && stamp.exists === true) return batch;
      await new Promise(done => setTimeout(done, 1000));
    }
    fail('LOCAL_BATCH_NOT_USABLE');
  }
  return Object.freeze({ endpoint: base, request, json, uploadBytes, uploadSite, usableBatch });
}
