import { useEffect, useState } from 'react';
import { Link, useNavigate } from 'react-router-dom';
import { ChevronDown, ChevronRight, FileText } from 'lucide-react';
import { supabase } from '../../lib/supabase';
import { useAuth } from '../../hooks/useAuth';
import { useBranch } from '../../hooks/useBranch';
import { formatMoney, formatAmount, dateText } from '../../lib/format';
import { WaitingSlips } from '../sales/PaymentProofs';

/*
 * "Needs you now" for the directors, grouped (2026-11-16, the user): one card a kind, with its number in
 * a badge. Payment slips: one card, opened to show them all. Weekly cash: one card with a summary, opened
 * to show each request; its document icon opens the report full screen as the PDF page, where the
 * director comments changes or approves it for payment. Other kinds go to their page.
 */
const LABEL = { proofs: 'Payment slips to confirm', cash: 'Weekly cash requests' };

export default function NeedsNow({ needs, canConfirm, inBranch, onChanged }) {
  const { organization } = useAuth();
  const money = v => formatMoney(v, organization?.currency_code);
  // the card the director opened stays open after a slip is confirmed and the board reloads, and after a
  // page refresh (2026-11-16, the user) — kept for this browser session
  const [openKey, setOpenKeyRaw] = useState(() => { try { return sessionStorage.getItem('mois:needs-open') || null; } catch { return null; } });
  const setOpenKey = k => { setOpenKeyRaw(k); try { if (k) sessionStorage.setItem('mois:needs-open', k); else sessionStorage.removeItem('mois:needs-open'); } catch { /* a convenience only */ } };
  const [cash, setCash] = useState(null);   // weekly cash requests with the directors
  const hasCash = needs.some(x => x.key === 'cash');
  useEffect(() => {
    if (!hasCash) { setCash([]); return; }
    supabase.from('cash_requests').select('id, branch_id, week_ending, source, lines:cash_request_lines(description, amount, approved_amount)').eq('status', 'with_directors')
      .order('week_ending', { ascending: false })
      .then(({ data }) => setCash((data || []).filter(r => inBranch(r.branch_id))));
  }, [hasCash]); // eslint-disable-line react-hooks/exhaustive-deps
  const asked = r => (r.lines || []).reduce((t, l) => t + Number(l.amount || 0), 0);
  const total = needs.reduce((t, x) => t + x.count, 0);

  return (
    <section className="dd-block dd-needs">
      <div className="dd-head"><span>Needs you now</span><span className="nn-badge" aria-label={`${total} items`}>{total}</span></div>
      <div className="nn-cards">
        {needs.map(x => {
          const expandable = (x.key === 'proofs' && canConfirm) || x.key === 'cash';
          const on = openKey === x.key;
          const summary = x.key === 'cash' && cash?.length
            ? `${money(cash.reduce((t, r) => t + asked(r), 0))} asked · ${cash.length === 1 ? dateText(cash[0].week_ending) : `${cash.length} weeks`}` : null;
          const head = <>
            <span className="nn-badge">{x.count}</span>
            <span className="nn-text"><strong>{LABEL[x.key] ?? x.label.charAt(0).toUpperCase() + x.label.slice(1)}</strong>{summary && <span className="pl-help">{summary}</span>}</span>
            {expandable ? (on ? <ChevronDown size={18} /> : <ChevronRight size={18} />) : <ChevronRight size={18} />}
          </>;
          return (
            <div key={x.key} className={`nn-card${on ? ' is-open' : ''}`}>
              {expandable
                ? <button type="button" className="nn-head" aria-expanded={on} onClick={() => setOpenKey(on ? null : x.key)}>{head}</button>
                : <Link to={x.to} className="nn-head">{head}</Link>}
              {on && x.key === 'proofs' && <WaitingSlips inBranch={inBranch} onChanged={onChanged} />}
              {on && x.key === 'cash' && <CashList rows={cash} asked={asked} money={money} />}
            </div>
          );
        })}
      </div>
    </section>
  );
}

function CashList({ rows, asked, money }) {
  const navigate = useNavigate();
  const { branches } = useBranch();
  if (!rows) return <span className="skeleton" />;
  const go = (r, view) => navigate(`/weekly-cash?open=${r.id}&branch=${r.branch_id}${view ? '&view=1' : ''}`);
  return (
    <div className="nn-list">
      {rows.map(r => {
        const ls = [...(r.lines || [])].sort((a, b) => Number(b.amount) - Number(a.amount));
        return (
          <div key={r.id} className="nn-item">
            <button type="button" className="nn-item-main" onClick={() => go(r, false)} title="Open the request">
              <strong>{branches.find(b => b.id === r.branch_id)?.name ?? 'Branch'} · {dateText(r.week_ending)}</strong>
              <span className="pl-help">{money(asked(r))} asked · {ls.length} line{ls.length === 1 ? '' : 's'}{r.source === 'excel' ? ' · from Excel' : ''}</span>
              <span className="nn-lines">{ls.slice(0, 3).map((l, k) => <span key={k}>{l.description} · {formatAmount(Number(l.amount))}</span>)}{ls.length > 3 && <span className="pl-help">+{ls.length - 3} more</span>}</span>
            </button>
            <button type="button" className="btn btn-primary btn-sm nn-pdf" onClick={() => go(r, true)} title="Open the report full screen (PDF page) — then comment or approve" aria-label="Open the report full screen">
              <FileText size={16} /> View
            </button>
          </div>
        );
      })}
    </div>
  );
}
