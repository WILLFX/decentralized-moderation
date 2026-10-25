// One pin for the local Bee storage artifact reader and prerequisite download.
import { createHash } from 'node:crypto';
import { isAbsolute, join } from 'node:path';
import { fail } from '../collections.mjs';

export const BEE_FACTORY_VERSION = '1.1.2';
export const BEE_FACTORY_INTEGRITY = 'sha512-DkUF13VZOXAATOD96EnG0MtxZ5XUzp4UcDW0rYJK4gFY3E4cHL1NOm+iZkl1BLnzQ88wTWBEP8Tzau+UdAeWdA==';
export const BEE_FACTORY_ARCHIVE_URL = 'https://registry.npmjs.org/@ethersphere/bee-factory/-/bee-factory-1.1.2.tgz';
export const BEE_FACTORY_METADATA_URL = 'https://registry.npmjs.org/@ethersphere%2Fbee-factory/1.1.2';
export const MAX_FACTORY_ARCHIVE_BYTES = 40 * 1024 * 1024;

export function verifyFactoryMetadata(value) {
  if (value?.name !== '@ethersphere/bee-factory' || value.version !== BEE_FACTORY_VERSION
      || value.dist?.integrity !== BEE_FACTORY_INTEGRITY || value.dist?.tarball !== BEE_FACTORY_ARCHIVE_URL)
    fail('INVALID_UPSTREAM_METADATA');
}
export function verifyFactoryArchive(bytes) {
  if (!(bytes instanceof Uint8Array) || bytes.length > MAX_FACTORY_ARCHIVE_BYTES
      || 'sha512-' + createHash('sha512').update(bytes).digest('base64') !== BEE_FACTORY_INTEGRITY)
    fail('FACTORY_PACKAGE_INTEGRITY_FAILED');
}

// Resolve the artifact cache independently of where callers store run data.
export function factoryArchivePath(sessionRoot) {
  if (typeof sessionRoot !== 'string' || !isAbsolute(sessionRoot))
    fail('ABSOLUTE_SESSION_ROOT_REQUIRED');
  return join(sessionRoot, 'preflight', `bee-factory-${BEE_FACTORY_VERSION}.tgz`);
}
