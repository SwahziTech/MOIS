/*
 * Files kept on this device (2026-11-11): photos of proofs added to the day's list must survive a
 * page reload like the list itself. localStorage cannot hold files, so they go in IndexedDB.
 * Every call fails quietly (private window, storage off): the page then works from memory only.
 */
const DB = 'mois-files', STORE = 'kv';
let opening = null;
function open() {
  if (!opening) opening = new Promise((res, rej) => {
    const r = indexedDB.open(DB, 1);
    r.onupgradeneeded = () => r.result.createObjectStore(STORE);
    r.onsuccess = () => res(r.result);
    r.onerror = () => rej(r.error);
  });
  return opening;
}
async function run(mode, fn) {
  const db = await open();
  return new Promise((res, rej) => {
    const tx = db.transaction(STORE, mode);
    const q = fn(tx.objectStore(STORE));
    tx.oncomplete = () => res(q?.result);
    tx.onerror = () => rej(tx.error);
  });
}
export async function getFiles(key) { try { return await run('readonly', s => s.get(key)); } catch { return undefined; } }
export async function putFiles(key, value) { try { await run('readwrite', s => s.put(value, key)); } catch { /* storage off */ } }
export async function dropFiles(key) { try { await run('readwrite', s => s.delete(key)); } catch { /* storage off */ } }
