import { useEffect, useState } from 'react';
import { Share2 } from 'lucide-react';

/*
 * Share an opened proof (2026-11-11, the user): on a phone it opens the share sheet — WhatsApp,
 * Gallery, Files…; on a computer that cannot share files, the picture is copied so it can be
 * pasted into WhatsApp (Ctrl+V), and anything else is downloaded.
 *
 * The file is fetched as soon as the window opens: a phone only allows sharing straight after
 * the tap, so there is no time to fetch it then.
 *   getBlob: async () => Blob   (prepared ahead; re-run when `deps` change)
 */
async function toPng(blob) {
  if (blob.type === 'image/png') return blob;
  const bmp = await createImageBitmap(blob);
  const c = document.createElement('canvas'); c.width = bmp.width; c.height = bmp.height;
  c.getContext('2d').drawImage(bmp, 0, 0);
  bmp.close?.();
  return new Promise(res => c.toBlob(res, 'image/png'));
}

export default function ShareButton({ getBlob, deps = [], name = 'proof', text = '', className = 'btn btn-ghost' }) {
  const [blob, setBlob] = useState(null);
  const [said, setSaid] = useState('');
  useEffect(() => {
    let live = true;
    setBlob(null);
    Promise.resolve().then(getBlob).then(b => { if (live && b) setBlob(b); }).catch(() => {});
    return () => { live = false; };
  }, deps); // eslint-disable-line react-hooks/exhaustive-deps
  useEffect(() => { if (!said) return undefined; const t = setTimeout(() => setSaid(''), 3500); return () => clearTimeout(t); }, [said]);
  if (!blob) return null;

  const ext = blob.type === 'application/pdf' ? 'pdf' : blob.type === 'image/png' ? 'png' : blob.type === 'text/plain' ? 'txt' : 'jpg';
  const file = new File([blob], `${name.replace(/\.[^.]+$/, '')}.${ext}`, { type: blob.type || 'image/jpeg' });
  async function share() {
    // 1. the phone's (or computer's) share sheet
    if (navigator.canShare?.({ files: [file] })) {
      try { await navigator.share({ files: [file], text: text || undefined }); return; }
      catch (e) { if (e?.name === 'AbortError') return; }
    }
    // 2. a computer: copy the picture, to paste into WhatsApp
    if (blob.type.startsWith('image/') && window.ClipboardItem && navigator.clipboard?.write) {
      try {
        await navigator.clipboard.write([new ClipboardItem({ 'image/png': toPng(blob) })]);
        setSaid('Copied — paste it in WhatsApp (Ctrl+V)');
        return;
      } catch { /* fall through */ }
    }
    // 3. otherwise: download it
    const a = document.createElement('a');
    a.href = URL.createObjectURL(file); a.download = file.name;
    document.body.appendChild(a); a.click(); a.remove();
    setTimeout(() => URL.revokeObjectURL(a.href), 5000);
    setSaid('Downloaded');
  }
  return (
    <>
      {said && <span className="share-said" role="status">{said}</span>}
      <button type="button" className={className} onClick={share} title="Share — WhatsApp and other apps"><Share2 size={14} /> Share</button>
    </>
  );
}
