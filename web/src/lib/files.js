/*
 * Files on Cloudflare R2 (2026-11-11, migration 117, web/worker): the same calls the app used with
 * Supabase Storage — files(bucket).upload(path, file) and files(bucket).createSignedUrl(path, secs,
 * { download }) — now through the MOIS file service. Paths are unchanged ('<org>/<branch>/…').
 * A file not yet on R2 is still read from Supabase Storage, so nothing is lost during the move.
 */
import { supabase } from './supabase';

const API = (import.meta.env.VITE_FILES_API || 'https://mois.swahzitech.workers.dev').replace(/\/$/, '');

async function signLink(key, write, download) {
  const { data } = await supabase.auth.getSession();
  const token = data.session?.access_token;
  if (!token) return { error: new Error('Sign in first.') };
  try {
    const r = await fetch(`${API}/api/files/sign`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json', Authorization: `Bearer ${token}` },
      body: JSON.stringify({ key, write, ...(download ? { download } : {}) }),
    });
    const body = await r.json().catch(() => ({}));
    // the service not there (not deployed yet, or down): say so, so the caller can use Supabase Storage meanwhile
    if (r.status === 404 || r.status === 405 || r.status >= 500 || !(r.headers.get('content-type') || '').includes('json')) {
      return { unavailable: true, error: new Error("We couldn't reach the file store.") };
    }
    if (!r.ok) return { error: new Error(body.error || "We couldn't reach the file store.") };
    return body;   // { url } or { missing: true }
  } catch {
    return { unavailable: true, error: new Error("We couldn't reach the file store. Check the connection and try again.") };
  }
}

export function files(bucket) {
  return {
    async upload(path, file, { contentType } = {}) {
      const s = await signLink(`${bucket}/${path}`, true);
      // until the R2 file service is live, files still go to Supabase Storage (moved to R2 afterwards)
      if (s.unavailable) return supabase.storage.from(bucket).upload(path, file, { contentType: contentType || file.type || undefined, upsert: false });
      if (s.error) return { data: null, error: s.error };
      try {
        const r = await fetch(s.url, { method: 'PUT', headers: { 'Content-Type': contentType || file.type || 'application/octet-stream' }, body: file });
        if (!r.ok) return { data: null, error: new Error((await r.text().catch(() => '')) || "The file wasn't saved.") };
        return { data: { path }, error: null };
      } catch {
        return { data: null, error: new Error("The file wasn't saved. Check the connection and try again.") };
      }
    },
    async createSignedUrl(path, seconds = 600, { download } = {}) {
      if (!path) return { data: null, error: new Error('No file.') };
      const s = await signLink(`${bucket}/${path}`, false, download || '');
      if (s.url) return { data: { signedUrl: s.url }, error: null };
      // not on R2 yet: the copy still in Supabase Storage
      return supabase.storage.from(bucket).createSignedUrl(path, seconds, download ? { download } : undefined);
    },
  };
}
