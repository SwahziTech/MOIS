import { useEffect, useState } from 'react';
import { createPortal } from 'react-dom';
import { X, Download, MessageSquare, Check, ExternalLink } from 'lucide-react';
import { PagePreview } from './WeeklyCashDocDialog';
import { pickPaper, openPdf, isPhone, pdfFile, shareOrOpenPdf } from '../../lib/weeklyCashDoc';

/*
 * The weekly cash report full screen, as the PDF page (2026-11-16, the user: directors open it on their
 * phones, read it, then comment changes or approve it for payment). The page fills the screen width and
 * scrolls; pinch to zoom. Save PDF keeps the file.
 *   canDecide: the director may send it back with a comment or approve it
 */
export default function WeeklyCashViewer({ doc, total, money, canDecide = false, busy = false, error = '', onApprove, onSendBack, onClose }) {
  const [mode, setMode] = useState(null);   // null | 'comment'
  const [note, setNote] = useState('');
  const setup = pickPaper(doc);
  // the PDF is made as the report opens (2026-11-21): a phone only shares or opens a file straight after the tap
  const [file, setFile] = useState(null);
  useEffect(() => {
    let live = true;
    pdfFile(doc, setup).then(f => { if (live) setFile(f); }).catch(() => {});
    return () => { live = false; };
  }, [doc]); // eslint-disable-line react-hooks/exhaustive-deps
  const pdfTap = () => (file ? shareOrOpenPdf(file) : openPdf(doc, setup));
  return createPortal(
    <div className="wcv" role="dialog" aria-modal="true" aria-label={doc.title}>
      <div className="wcv-bar">
        <strong className="wcv-title">{doc.title}</strong>
        <button type="button" className="btn btn-ghost btn-sm" title={isPhone() ? 'Open the PDF with an app on this phone' : 'Save as PDF'} onClick={pdfTap}>{isPhone() ? <ExternalLink size={16} /> : <Download size={16} />} PDF</button>
        {/* close: always top right, red on hover (2026-11-21, the user — the standard everywhere) */}
        <button type="button" className="close-x" aria-label="Close" title="Close" onClick={onClose}><X size={18} /></button>
      </div>
      <div className="wcv-page"><PagePreview doc={doc} setup={setup} fitWidth /></div>
      {canDecide && (
        <div className="wcv-foot">
          {error && <p className="text-sm text-error" role="alert" style={{ margin: 0 }}>{error}</p>}
          {mode === 'comment' ? <>
            <textarea className="form-input" rows={3} autoFocus placeholder="What should change?" value={note} onChange={e => setNote(e.target.value)} />
            <div className="wcv-actions">
              <button type="button" className="btn btn-outline" onClick={() => setMode(null)}>Back</button>
              <button type="button" className={`btn btn-primary${busy ? ' btn-loading' : ''}`} disabled={busy || !note.trim()} onClick={() => onSendBack(note.trim())}>Send back to change</button>
            </div>
          </> : (
            <div className="wcv-actions">
              <button type="button" className="btn btn-outline" onClick={() => setMode('comment')}><MessageSquare size={15} /> Comment</button>
              <button type="button" className={`btn btn-primary${busy ? ' btn-loading' : ''}`} disabled={busy} onClick={() => onApprove()}><Check size={15} /> Approve {money(total)}</button>
            </div>
          )}
        </div>
      )}
    </div>,
    document.body,
  );
}
