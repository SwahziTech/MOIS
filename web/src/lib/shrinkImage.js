/*
 * Photos are made smaller before they are uploaded (2026-11-11, the user: storage costs).
 * A phone photo of 3–5 MB becomes a JPEG of about 200–400 KB, at most 1600 px on its long
 * side — slip text stays sharp and can still be zoomed. PDFs, small images, and pictures the
 * browser cannot read (e.g. HEIC on a computer) are kept exactly as they were.
 */
export async function shrinkImage(file, { max = 1600, quality = 0.85 } = {}) {
  if (!file || !file.type?.startsWith('image/') || file.type === 'image/gif' || file.type === 'image/svg+xml') return file;
  if (file.size < 300 * 1024) return file;   // already small (most screenshots, WhatsApp images)
  let bmp;
  try { bmp = await createImageBitmap(file, { imageOrientation: 'from-image' }); } catch { return file; }
  try {
    const k = Math.min(1, max / Math.max(bmp.width, bmp.height));
    const w = Math.round(bmp.width * k), h = Math.round(bmp.height * k);
    const c = document.createElement('canvas');
    c.width = w; c.height = h;
    const g = c.getContext('2d');
    g.fillStyle = '#fff'; g.fillRect(0, 0, w, h);   // a see-through PNG gets a white page, not black
    g.drawImage(bmp, 0, 0, w, h);
    const blob = await new Promise(res => c.toBlob(res, 'image/jpeg', quality));
    if (!blob || blob.size >= file.size) return file;
    const name = `${(file.name || 'photo').replace(/\.[^.]+$/, '')}.jpg`;
    return new File([blob], name, { type: 'image/jpeg', lastModified: file.lastModified });
  } catch { return file; } finally { bmp.close?.(); }
}
