// Ubuntu WSL prerequisite and upstream-artifact check. Does not install software,
// start containers, use a wallet, modify project sources or publish anything.
import { execFile } from 'node:child_process';
import { promisify } from 'node:util';
import { mkdir, readFile, writeFile } from 'node:fs/promises';
import { BEE_FACTORY_INTEGRITY, BEE_FACTORY_ARCHIVE_URL, BEE_FACTORY_METADATA_URL, MAX_FACTORY_ARCHIVE_BYTES, verifyFactoryMetadata, verifyFactoryArchive, factoryArchivePath } from '../local-bee/storage-artifact.mjs';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';

const exec = promisify(execFile);
const archivePath = factoryArchivePath(fileURLToPath(new URL('./', import.meta.url)));
const directory = dirname(archivePath);
const summary = { kind: 'isolated-bee-preflight', nodeVersion: process.version,
  dockerServerVersion: null, packageVersion: null, packageIntegrity: null, packageArchive: null, issues: [] };
async function bounded(url, maximum) {
  const result = await fetch(url, { redirect: 'error', signal: AbortSignal.timeout(60000),
    headers: { Accept: 'application/json, application/octet-stream' } });
  if (!result.ok || result.redirected || !result.body) throw new Error('UPSTREAM_READ_FAILED');
  const reader = result.body.getReader(); const chunks = []; let length = 0;
  try {
    while (true) {
      const { done, value } = await reader.read(); if (done) break;
      length += value.length; if (length > maximum) throw new Error('UPSTREAM_SIZE_LIMIT');
      chunks.push(Buffer.from(value));
    }
    return Buffer.concat(chunks);
  } finally { try { await reader.cancel(); } catch { /* Source may already be closed. */ } }
}
if (process.platform !== 'linux') {
  console.error('Run this check in Ubuntu WSL.'); process.exitCode = 1;
} else {
  try {
    const { stdout } = await exec('docker', ['version', '--format', '{{.Server.Version}}'], { timeout: 15000, maxBuffer: 65536 });
    if (!/^\d+\.\d+(?:\.\d+)?(?:[A-Za-z0-9_.+-]*)?$/u.test(stdout.trim())) throw new Error();
    summary.dockerServerVersion = stdout.trim();
  } catch { summary.issues.push('DOCKER_ENGINE_NOT_AVAILABLE_IN_WSL'); }
  try {
    const metadata = JSON.parse(await bounded(BEE_FACTORY_METADATA_URL, 2 * 1024 * 1024));
    verifyFactoryMetadata(metadata);
    const archive = await bounded(BEE_FACTORY_ARCHIVE_URL, MAX_FACTORY_ARCHIVE_BYTES);
    verifyFactoryArchive(archive);
    const integrity = BEE_FACTORY_INTEGRITY;
    await mkdir(directory, { recursive: true });
    const path = archivePath;
    try {
      const existing = await readFile(path);
      if (!existing.equals(archive)) throw new Error('EXISTING_ARTIFACT_MISMATCH');
    } catch (error) {
      if (error.code !== 'ENOENT') throw error;
      await writeFile(path, archive, { flag: 'wx' });
    }
    summary.packageVersion = metadata.version; summary.packageIntegrity = integrity; summary.packageArchive = path;
    await writeFile(join(directory, `bee-factory-${metadata.version}-metadata.json`), JSON.stringify({
      name: metadata.name, version: metadata.version, dist: metadata.dist, engines: metadata.engines ?? null,
    }, null, 2) + '\n');
  } catch (error) {
    summary.issues.push(['INVALID_UPSTREAM_METADATA', 'UPSTREAM_INTEGRITY_MISMATCH', 'EXISTING_ARTIFACT_MISMATCH',
      'UPSTREAM_SIZE_LIMIT', 'UPSTREAM_READ_FAILED', 'FACTORY_PACKAGE_INTEGRITY_FAILED'].includes(error.message) ? error.message : 'UPSTREAM_ARTIFACT_UNAVAILABLE');
  }
  await mkdir(directory, { recursive: true });
  await writeFile(join(directory, 'result.json'), JSON.stringify(summary, null, 2) + '\n');
  console.log(JSON.stringify(summary, null, 2));
  console.log('Preflight only: no installation, containers, contracts or project changes.');
  if (summary.issues.length) process.exitCode = 1;
}
