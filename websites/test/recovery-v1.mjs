// Synthetic WebCrypto tests of the Rust recovery implementation and v1 wire format.
import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import { resolve, join } from 'node:path';
import { pathToFileURL } from 'node:url';
import { webcrypto } from 'node:crypto';
import { readBoundedFileBytes, writeVerifiedCheckpointFile } from '../../tools/files.mjs';

const directory=resolve(process.argv[2] ?? 'target/vault-interop');
await writeVerifiedCheckpointFile(join(directory,'package.json'),'{"type":"module"}\n');
Object.defineProperty(globalThis,'crypto',{value:webcrypto,configurable:true});
const wasm=await import(pathToFileURL(join(directory,'vault_interop.js')));
await wasm.default({module_or_path:await readBoundedFileBytes(join(directory,'vault_interop_bg.wasm'),8*1024*1024)});
const fixture=JSON.parse(await readFile(new URL('./fixtures/recovery-v1.json',import.meta.url),'utf8'));
const password='synthetic-format-v1-fixture-only';
assert.deepEqual(JSON.parse(await wasm.decrypt_test(JSON.stringify(fixture.envelope),password)),fixture.payload);
console.log('PASS encrypted format-v1 fixture decrypts to its expected payload');
const one=await wasm.encrypt_test(JSON.stringify(fixture.payload),password);
const two=await wasm.encrypt_test(JSON.stringify(fixture.payload),password);
assert.notEqual(one,two);
const output=JSON.parse(one);
assert.equal(output.format,'moderator-vote-vault');
assert.equal(output.version,1);
assert.equal(output.kdf.name,'PBKDF2');
assert.equal(output.kdf.hash,'SHA-256');
assert.equal(output.kdf.iterations,310000);
assert.equal(output.cipher.name,'AES-GCM');
assert.deepEqual(JSON.parse(await wasm.decrypt_test(one,password)),fixture.payload);
assert.deepEqual(JSON.parse(await wasm.decrypt_test(two,password)),fixture.payload);
console.log('PASS Rust recovery encryption uses fresh randomness and preserves the payload');
await assert.rejects(wasm.decrypt_test(one,'wrong-password'));
const tampered=JSON.parse(one);tampered.cipher.data=(tampered.cipher.data[0]==='0'?'1':'0')+tampered.cipher.data.slice(1);
await assert.rejects(wasm.decrypt_test(JSON.stringify(tampered),password));
const invalid=JSON.parse(one);invalid.kdf.iterations=1;
await assert.rejects(wasm.decrypt_test(JSON.stringify(invalid),password));
console.log('PASS wrong password, modified ciphertext and weakened KDF are rejected');


// Minimal DOM storage surface. Crypto remains Node WebCrypto; no wallet/network.
const storage = new Map();
let failWrite = false;
// web_sys::window casts js_sys::global(), which is globalThis in Node.
class SyntheticWindow {
  static [Symbol.hasInstance](value) { return value === globalThis; }
}
globalThis.Window = SyntheticWindow;
globalThis.window = globalThis;
window.localStorage = {
  getItem(key) { return storage.get(key) ?? null; },
  setItem(key, value) {
    if (failWrite) throw new Error('synthetic storage failure');
    storage.set(key, value);
  },
};
const key = 'moderator-vote-vault-v1';
const record = structuredClone(fixture.payload.votes[0]);
const second = {...record, caseId: '10'};
const json = JSON.stringify;
const records = vault => JSON.parse(vault.records());
const rejects = (operation, expected) => assert.rejects(operation, error => error === expected);
const fresh = () => { storage.clear(); failWrite = false; return new wasm.LifecycleVault(); };

let vault = fresh();
await vault.unlock(password);
await vault.save(json(record));
assert.equal(vault.covered(json(record)), false);
const backup = await vault.export_backup();
assert.equal(vault.covered(json(record)), false, 'export is not saved-file verification');
await vault.save(json(second));
assert.equal(await vault.verify(backup), 1);
assert.equal(vault.covered(json(record)), true);
assert.equal(vault.covered(json(second)), false, 'only exact verified records are covered');
const persisted = storage.get(key);
vault.lock();
assert.equal(vault.unlocked(), false);
await rejects(vault.unlock('wrong-password'), 'BACKUP_AUTHENTICATION_FAILED');
assert.equal(storage.get(key), persisted);
await vault.unlock(password);
assert.deepEqual(records(vault), [record, second]);
assert.equal(vault.covered(json(record)), true, 'verified coverage survives reload');
assert.equal(vault.covered(json(second)), false);
console.log('PASS production vault persists secrets and requires exact saved-file verification');

// Mutation failures must preserve both durable and in-memory records/coverage.
const beforeRecords = records(vault);
const third = {...record, caseId: '11'};
failWrite = true;
await rejects(vault.save(json(third)), 'STORAGE_FAILED');
assert.deepEqual(records(vault), beforeRecords);
assert.equal(storage.get(key), persisted);
assert.equal(vault.covered(json(record)), true);
assert.equal(vault.covered(json(second)), false);
await rejects(vault.verify(await vault.export_backup()), 'STORAGE_FAILED');
assert.equal(vault.covered(json(second)), false);
assert.equal(storage.get(key), persisted);
failWrite = false;
const changed = {...record, salt: '0x' + '55'.repeat(32)};
await rejects(vault.save(json(changed)), 'VOTE_CONFLICT');
assert.deepEqual(records(vault), beforeRecords);
assert.equal(storage.get(key), persisted);
const conflictingEnvelope = await wasm.encrypt_test(json({...fixture.payload, votes:[changed], backedUp:[]}), password);
await rejects(vault.import_backup(conflictingEnvelope, password), 'VOTE_CONFLICT');
assert.deepEqual(records(vault), beforeRecords);
assert.equal(storage.get(key), persisted);
const otherTab = new wasm.LifecycleVault();
await otherTab.unlock(password);
await otherTab.save(json(third));
const otherTabBytes = storage.get(key);
await rejects(vault.save(json({...record, caseId:'12'})), 'VAULT_CHANGED');
assert.deepEqual(records(vault), beforeRecords);
assert.equal(storage.get(key), otherTabBytes);
console.log('PASS write failure, conflicting recovery and another tab cannot overwrite prior state');

vault.lock();
await rejects(vault.import_backup(backup, password), 'VAULT_LOCKED');
assert.equal(storage.get(key), otherTabBytes);
vault = fresh();
failWrite = true;
await rejects(vault.import_backup(backup, password), 'STORAGE_FAILED');
assert.equal(vault.unlocked(), false);
assert.equal(storage.has(key), false);
failWrite = false;
assert.equal(await vault.import_backup(backup, password), 1);
assert.equal(vault.covered(json(record)), true);
const importedBytes = storage.get(key);
vault.lock();
await vault.unlock(password);
assert.deepEqual(records(vault), [record]);
assert.equal(storage.get(key), importedBytes);
console.log('PASS locked import refuses overwrite and failed empty-vault import is atomic');

// Recovery may use a different password from the local vault.
vault = fresh();
await vault.unlock('synthetic-local-password');
assert.equal(await vault.import_backup(backup, password), 1);
assert.equal(vault.covered(json(record)), true);
vault.lock();
await rejects(vault.unlock(password), 'BACKUP_AUTHENTICATION_FAILED');
await vault.unlock('synthetic-local-password');
assert.deepEqual(records(vault), [record]);
console.log('PASS recovery import retains the distinct local encryption password');

// Pause the actual production encrypt await, lock, then resume it.
const beforeLockBytes = storage.get(key);
let releaseEncrypt;
let enteredEncrypt;
const entered = new Promise(resolve => { enteredEncrypt = resolve; });
const delayed = new Promise(resolve => { releaseEncrypt = resolve; });
const subtle = new Proxy(webcrypto.subtle, {
  get(target, name) {
    if (name === 'encrypt') return async (...args) => {
      enteredEncrypt();
      await delayed;
      return target.encrypt(...args);
    };
    const value = Reflect.get(target, name);
    return typeof value === 'function' ? value.bind(target) : value;
  },
});
Object.defineProperty(globalThis,'crypto',{configurable:true,value:{
  subtle, getRandomValues:webcrypto.getRandomValues.bind(webcrypto),
}});
const pending = vault.save(json(second));
let timeout;
try {
  await Promise.race([entered, new Promise((_,reject) => {
    timeout = setTimeout(() => reject(new Error('production encrypt hook not reached')), 10000);
  })]);
  await rejects(vault.save(json(third)), 'VAULT_BUSY');
  vault.lock();
  releaseEncrypt();
  await rejects(pending, 'VAULT_LOCKED');
  assert.equal(vault.unlocked(), false);
  assert.equal(storage.get(key), beforeLockBytes);
} finally {
  clearTimeout(timeout);
  releaseEncrypt();
  Object.defineProperty(globalThis,'crypto',{value:webcrypto,configurable:true});
}
await vault.unlock('synthetic-local-password');
assert.deepEqual(records(vault), [record], 'interrupted save never persists the new secret');
console.log('PASS lock during production asynchronous encryption prevents secret persistence');
