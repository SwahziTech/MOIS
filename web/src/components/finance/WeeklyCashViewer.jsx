import { useState } from 'react';
import { createPortal } from 'react-dom';
import { X, Download, MessageSquare, Check } from 'lucide-react';
import { PagePreview } from './WeeklyCashDocDialog';
import { pickPaper, downloadPdf } from '../../lib/weeklyCashDoc';

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
  return createPortal(
    <div className="wcv" role="dialog" aria-modal="true" aria-label={doc.title}>
      <div className="wcv-bar">
        <button type="button" className="btn btn-ghost btn-sm" aria-label="Close" onClick={onClose}><X size={18} /></button>
        <strong className="wcv-title">{doc.title}</strong>
        <button type="button" className="btn btn-ghost btn-sm" title="Save as PDF" onClick={() => downloadPdf(doc, setup)}><Download size={16} /> PDF</button>
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
