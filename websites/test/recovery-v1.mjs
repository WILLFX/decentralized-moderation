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

// M7: exercise the production encrypted vault, not a parallel JavaScript model.
vault = fresh();
await vault.unlock(password);
await vault.save(json(record));
assert.equal(vault.correctable(json(record)), true);
const beforeChangeBackup = await vault.export_backup();
await vault.verify(beforeChangeBackup);
const originalFingerprint = JSON.parse(await wasm.decrypt_test(storage.get(key), password)).backedUp[0];
const corrected = {...record, vote:record.vote === 1 ? 2 : 1, salt:'0x'+'ab'.repeat(32), commitment:'0x'+'cd'.repeat(32)};
const beforeCorrection = storage.get(key);
failWrite = true;
await rejects(vault.correct(json(record),json(corrected)), 'STORAGE_FAILED');
assert.equal(storage.get(key), beforeCorrection);
assert.deepEqual(records(vault), [record]);
assert.equal(vault.correctable(json(record)), true);
failWrite = false;
await vault.correct(json(record),json(corrected));
assert.deepEqual(records(vault), [corrected,record]);
assert.equal(vault.correctable(json(record)), false);
assert.equal(vault.correctable(json(corrected)), true);
assert.equal(vault.covered(json(corrected)), false);
let correctedPayload = JSON.parse(await wasm.decrypt_test(storage.get(key), password));
assert.equal(correctedPayload.version,2);
assert.deepEqual(correctedPayload.archivedVotes,[record]);
assert.deepEqual(correctedPayload.backedUp,[originalFingerprint]);
assert.equal(await vault.verify(beforeChangeBackup),1);
assert.equal(vault.covered(json(corrected)),false,'old recovery never covers a replacement');
const afterChangeBackup = await vault.export_backup();
assert.equal(await vault.verify(afterChangeBackup),2);
assert.equal(vault.covered(json(corrected)),true);
assert.equal(JSON.parse(await wasm.decrypt_test(storage.get(key),password)).backedUp.length,2);
console.log('PASS M7 correction retains exact old bytes and coverage; replacement requires new recovery');

await vault.import_backup(beforeChangeBackup,password);
assert.deepEqual(records(vault),[corrected,record],'old import does not roll active choice back');
assert.equal(vault.correctable(json(corrected)),false,'import does not mint correction authority');
await rejects(vault.correct(json(corrected),json(record)), 'CHOICE_PROTECTED');
vault.lock(); await vault.unlock(password);
assert.equal(vault.correctable(json(corrected)),false,'unlock cannot infer unsent from absent journal');
assert.deepEqual(records(vault),[corrected,record]);
vault = fresh();
await vault.import_backup(afterChangeBackup,password);
assert.deepEqual(records(vault),[corrected,record]);
assert.equal(vault.correctable(json(corrected)),false);
assert.equal(vault.covered(json(corrected)),true);
console.log('PASS M7 v2 round trip retains both secrets; reload/import cannot recreate unsent authority');

vault = fresh(); await vault.unlock(password); await vault.save(json(record));
vault.seal(json(record));
await rejects(vault.correct(json(record),json(corrected)), 'CHOICE_PROTECTED');
await vault.verify(await vault.export_backup());
assert.equal(vault.correctable(json(record)),false,'verifying recovery cannot clear an attempted send');
assert.deepEqual(records(vault),[record]);
vault = fresh(); await vault.unlock(password); await vault.save(json(record));
const concurrent = new wasm.LifecycleVault(); await concurrent.unlock(password); await concurrent.save(json(second));
assert.equal(vault.correctable(json(record)),false);
await rejects(vault.correct(json(record),json(corrected)), 'CHOICE_PROTECTED');
assert.deepEqual(JSON.parse(await wasm.decrypt_test(storage.get(key),password)).votes,[record,second]);
console.log('PASS M7 attempted send and cross-tab changes block correction without deleting secrets');

// An interrupted correction must not persist a replacement or mint authority.
vault = fresh(); await vault.unlock(password); await vault.save(json(record));
const beforeInterruptedCorrection = storage.get(key);
let correctionEntered, correctionRelease;
const correctionReached = new Promise(resolve=>{correctionEntered=resolve;});
const correctionDelay = new Promise(resolve=>{correctionRelease=resolve;});
const correctionSubtle = new Proxy(webcrypto.subtle,{get(target,name){
 if(name==='encrypt') return async (...args)=>{correctionEntered();await correctionDelay;return target.encrypt(...args);};
 const value=Reflect.get(target,name);return typeof value==='function'?value.bind(target):value;
}});
Object.defineProperty(globalThis,'crypto',{configurable:true,value:{subtle:correctionSubtle,getRandomValues:webcrypto.getRandomValues.bind(webcrypto)}});
const correcting=vault.correct(json(record),json(corrected));
let correctionTimeout;
try {
 await Promise.race([correctionReached,new Promise((_,reject)=>{correctionTimeout=setTimeout(()=>reject(new Error('correction encrypt not reached')),10000);})]);
 vault.lock(); correctionRelease(); await rejects(correcting,'VAULT_LOCKED');
 assert.equal(storage.get(key),beforeInterruptedCorrection);
} finally {
 clearTimeout(correctionTimeout); correctionRelease(); Object.defineProperty(globalThis,'crypto',{value:webcrypto,configurable:true});
}
await vault.unlock(password);assert.deepEqual(records(vault),[record]);assert.equal(vault.correctable(json(record)),false);
console.log('PASS M7 lock during correction retains the original ciphertext and invalidates authority');
