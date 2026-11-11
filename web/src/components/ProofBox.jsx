import { useState } from 'react';
import { Plus, X, FileText } from 'lucide-react';
import { useFileUrl } from './ProofPreview';
import { shrinkImage } from '../lib/shrinkImage';

/*
 * The proof of a payment, entered like a message (2026-11-06, the user): one
 * box — type or paste the SMS (muamala); drop or paste a photo or screenshot
 * onto it; + to choose a photo or PDF from the device. The file shows as a
 * thumbnail in the box (click for the full photo, × to remove). Paste and drop
 * reach the hidden file input through lib/fileDrop.js, as on every upload.
 */
export default function ProofBox({ file, onFile, text, onText, keptName = null, compact = false, placeholder = 'Paste the SMS (muamala), or drop / paste a photo of the slip…' }) {
  const url = useFileUrl(file);
  const [big, setBig] = useState(false);
  const isImage = file?.type?.startsWith('image/');
  async function pick(e) {
    const f = e.target.files?.[0];
    e.target.value = '';
    if (f) { setBig(false); onFile(await shrinkImage(f)); }   // photos made smaller before upload (2026-11-11)
  }
  // compact (2026-11-08): one line the height of a field, for forms (Record a sale)
  if (compact) return (
    <div className="proof-box proof-box-compact">
      <label className="proof-box-add" title="Add a photo or PDF from this device" aria-label="Add a photo or PDF">
        <Plus size={15} />
        <input type="file" accept="image/*,application/pdf" hidden onChange={pick} />
      </label>
      {file && (
        <span className="proof-chip">
          <button type="button" className="proof-chip-thumb" title={isImage ? 'Open the photo' : 'Open the PDF'} onClick={() => window.open(url, '_blank', 'noopener')}>
            {isImage && url ? <img src={url} alt="" /> : <FileText size={15} aria-hidden="true" />}
          </button>
          <button type="button" className="proof-chip-x" aria-label="Remove the file" onClick={() => onFile(null)}><X size={13} /></button>
        </span>
      )}
      <input className="proof-box-line" value={text} placeholder={file ? 'Photo added' : 'Paste SMS, or + / drop a photo'} aria-label="Proof: the SMS text" onChange={e => onText(e.target.value)} />
    </div>
  );
  return (
    <div className="proof-box">
      {(file || keptName) && (
        <div className="proof-box-files">
          {file ? (
            <span className="proof-chip">
              <button type="button" className="proof-chip-thumb" title={isImage ? 'Show the photo' : 'Open the PDF'}
                onClick={() => (isImage ? setBig(b => !b) : window.open(url, '_blank', 'noopener'))}>
                {isImage && url ? <img src={url} alt="" /> : <FileText size={18} aria-hidden="true" />}
              </button>
              <span className="proof-chip-name">{file.name}</span>
              <button type="button" className="proof-chip-x" aria-label="Remove the file" onClick={() => { setBig(false); onFile(null); }}><X size={13} /></button>
            </span>
          ) : <span className="proof-chip proof-chip-kept">Kept: {keptName}</span>}
        </div>
      )}
      {big && isImage && url && <button type="button" className="pp-big" title="Hide" onClick={() => setBig(false)}><img src={url} alt="The proof" className="pp-photo" /></button>}
      <textarea className="proof-box-text" rows={3} value={text} placeholder={placeholder} aria-label="Proof: the SMS text" onChange={e => onText(e.target.value)} />
      <div className="proof-box-bar">
        <label className="proof-box-add" title="Add a photo or PDF from this device" aria-label="Add a photo or PDF">
          <Plus size={16} />
          <input type="file" accept="image/*,application/pdf" hidden onChange={pick} />
        </label>
        <span className="pl-help">Photo, PDF or SMS</span>
      </div>
    </div>
  );
}
