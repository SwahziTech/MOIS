import { useEffect, useState } from 'react';
import { FileImage, FileText } from 'lucide-react';

/*
 * The chosen proof before it is posted (2026-11-04, the user): a photo shows
 * as a thumbnail — click it for the full photo in the window; a PDF shows its
 * mark and opens in a new tab. Used by every proof upload.
 */
export function useFileUrl(file) {
  const [url, setUrl] = useState('');
  useEffect(() => {
    if (!file) { setUrl(''); return undefined; }
    const u = URL.createObjectURL(file);
    setUrl(u);
    return () => URL.revokeObjectURL(u);
  }, [file]);
  return url;
}

/** The thumbnail; with `large` set, the full photo below (controlled by the caller) */
export function ProofThumb({ file, url, onOpen }) {
  const isImage = file?.type?.startsWith('image/');
  const isPdf = file && !isImage;
  return (
    <button type="button" className="ru-thumb ru-thumb-btn" title={file ? (isImage ? 'Show the photo' : 'Open the PDF') : undefined}
      disabled={!file} onClick={() => (isPdf ? window.open(url, '_blank', 'noopener') : onOpen?.())}>
      {isImage && url ? <img src={url} alt="The proof" /> : isPdf ? <><FileText size={22} aria-hidden="true" /><span className="ru-thumb-tag">PDF</span></> : <FileImage size={24} aria-hidden="true" />}
    </button>
  );
}

/** A file row's preview area: thumbnail, and the full photo when opened */
export default function ProofPreview({ file, children }) {
  const url = useFileUrl(file);
  const [big, setBig] = useState(false);
  useEffect(() => { setBig(false); }, [file]);
  return (
    <>
      <div className="ru-file-row">
        <ProofThumb file={file} url={url} onOpen={() => setBig(b => !b)} />
        {children}
      </div>
      {big && file?.type?.startsWith('image/') && url && (
        <button type="button" className="pp-big" title="Hide" onClick={() => setBig(false)}><img src={url} alt="The proof" className="pp-photo" /></button>
      )}
    </>
  );
}
