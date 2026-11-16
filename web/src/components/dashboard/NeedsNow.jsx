import { useEffect, useState } from 'react';
import { Link } from 'react-router-dom';
import { ChevronDown, ChevronRight, FileText } from 'lucide-react';
import { supabase } from '../../lib/supabase';
import { useAuth } from '../../hooks/useAuth';
import { useBranch } from '../../hooks/useBranch';
import { formatMoney, formatAmount, dateText } from '../../lib/format';
import { WaitingSlips } from '../sales/PaymentProofs';
import { PayModal } from './DirectorPayments';
import WeeklyCash from '../../pages/WeeklyCash';
import { loadOrdersToPay } from '../../lib/directorBoard';

/*
 * "Needs you now" for the directors, grouped (2026-11-16, the user): one card a kind, with its number in
 * a badge. Payment slips: one card, opened to show them all. Weekly cash: one card with a summary, opened
 * to show each request; its document icon opens the report full screen as the PDF page, where the
 * director comments changes or approves it for payment. Other kinds go to their page.
 */
const LABEL = { proofs: 'Payment slips to confirm', cash: 'Weekly cash requests', orders: 'Orders to pay' };

export default function NeedsNow({ needs, canConfirm, inBranch, onChanged }) {
  const { organization } = useAuth();
  const money = v => formatMoney(v, organization?.currency_code);
  // the card the director opened stays open after a slip is confirmed and the board reloads, and after a
  // page refresh (2026-11-16, the user) — kept for this browser session
  const [openKey, setOpenKeyRaw] = useState(() => { try { return sessionStorage.getItem('mois:needs-open') || null; } catch { return null; } });
  const setOpenKey = k => { setOpenKeyRaw(k); try { if (k) sessionStorage.setItem('mois:needs-open', k); else sessionStorage.removeItem('mois:needs-open'); } catch { /* a convenience only */ } };
  const [cash, setCash] = useState(null);   // weekly cash requests with the directors, or approved and still to pay
  const [reloadKey, setReloadKey] = useState(0);
  const hasCash = needs.some(x => x.key === 'cash');
  useEffect(() => {
    if (!hasCash) { setCash([]); return; }
    supabase.from('cash_requests').select('id, branch_id, week_ending, source, status, lines:cash_request_lines(description, amount, approved_amount)').in('status', ['with_directors', 'approved'])
      .order('week_ending', { ascending: false })
      .then(({ data }) => setCash((data || []).filter(r => inBranch(r.branch_id))));
  }, [hasCash, reloadKey]); // eslint-disable-line react-hooks/exhaustive-deps
  const asked = r => (r.lines || []).reduce((t, l) => t + Number(l.amount || 0), 0);
  // pay first (129): approved orders, paid before the goods come
  const [orders, setOrders] = useState(null);
  const hasOrders = needs.some(x => x.key === 'orders');
  useEffect(() => {
    if (!hasOrders) { setOrders([]); return; }
    loadOrdersToPay().then(rows => setOrders(rows.filter(r => inBranch(r.branch_id))));
  }, [hasOrders, reloadKey]); // eslint-disable-line react-hooks/exhaustive-deps
  const total = needs.reduce((t, x) => t + x.count, 0);

  return (
    <section className="dd-block dd-needs">
      <div className="dd-head"><span>Needs you now</span><span className="nn-badge" aria-label={`${total} items`}>{total}</span></div>
      <div className="nn-cards">
        {needs.map(x => {
          const expandable = (x.key === 'proofs' && canConfirm) || x.key === 'cash' || x.key === 'orders';
          const on = openKey === x.key;
          const toApprove = (cash || []).filter(r => r.status === 'with_directors'), toPay = (cash || []).filter(r => r.status === 'approved');
          const summary = x.key === 'orders' && orders?.length ? money(orders.reduce((t, r) => t + r.amount, 0))
            : x.key === 'cash' && cash?.length
            ? [toApprove.length ? `${toApprove.length} to approve · ${money(toApprove.reduce((t, r) => t + asked(r), 0))}` : null,
               toPay.length ? `${toPay.length} to pay · ${money(toPay.reduce((t, r) => t + asked(r), 0))}` : null].filter(Boolean).join(' · ') : null;
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
              {on && x.key === 'orders' && <OrderList rows={orders} money={money} onPaid={() => { setReloadKey(k => k + 1); onChanged?.(); }} />}
              {on && x.key === 'cash' && <CashList rows={cash} asked={asked} money={money} onPaid={() => { setReloadKey(k => k + 1); onChanged?.(); }} />}
            </div>
          );
        })}
      </div>
    </section>
  );
}

function OrderList({ rows, money, onPaid }) {
  const { branches } = useBranch();
  const { canAt } = useAuth();
  const [paying, setPaying] = useState(null);
  if (!rows) return <span className="skeleton" />;
  return (
    <div className="nn-list">
      {rows.map(r => (
        <div key={r.id} className="nn-item">
          <Link to="/orders" className="nn-item-main" title="Open Orders">
            <strong>{r.supplier?.name ?? 'Supplier'} · {money(r.amount)}</strong>
            <span className="pl-help">Order #{r.po_no} · {branches.find(b => b.id === r.branch_id)?.name ?? 'Branch'} · {dateText(r.order_date)}{r.priced ? '' : ' · a price is missing'}</span>
          </Link>
          {canAt('finance.pay', r.branch_id, null) && r.priced && (
            <button type="button" className="btn btn-primary btn-sm nn-pdf" onClick={() => setPaying(r)} title="Pay it now — the purchase is recorded as coming later, deliveries as they arrive">Pay</button>
          )}
        </div>
      ))}
      {paying && <PayModal preset={{ kind: 'supplier', branch: paying.branch_id, ref: 'po:' + paying.id }} onClose={() => setPaying(null)} onSaved={() => { setPaying(null); onPaid?.(); }} />}
    </div>
  );
}

function CashList({ rows, asked, money, onPaid }) {
  const { branches } = useBranch();
  const { canAt } = useAuth();
  const [paying, setPaying] = useState(null);   // an approved request being paid
  const [viewing, setViewing] = useState(null);   // the report open full screen, here (2026-11-16)
  if (!rows) return <span className="skeleton" />;
  const go = r => setViewing(r);   // the document opens here, over this page
  return (
    <div className="nn-list">
      {rows.map(r => {
        const ls = [...(r.lines || [])].sort((a, b) => Number(b.amount) - Number(a.amount));
        return (
          <div key={r.id} className="nn-item">
            <button type="button" className="nn-item-main" onClick={() => go(r, false)} title="Open the report">
              <strong>{branches.find(b => b.id === r.branch_id)?.name ?? 'Branch'} · {dateText(r.week_ending)}</strong>
              <span className="pl-help"><span className={`badge ${r.status === 'approved' ? 'badge-info' : 'badge-warning'}`}>{r.status === 'approved' ? 'Approved · to pay' : 'To approve'}</span> {money(asked(r))} · {ls.length} line{ls.length === 1 ? '' : 's'}{r.source === 'excel' ? ' · from Excel' : ''}</span>
              <span className="nn-lines">{ls.slice(0, 3).map((l, k) => <span key={k}>{l.description} · {formatAmount(Number(l.amount))}</span>)}{ls.length > 3 && <span className="pl-help">+{ls.length - 3} more</span>}</span>
            </button>
            {r.status === 'approved' && canAt('finance.pay', r.branch_id, null) && (
              <button type="button" className="btn btn-primary btn-sm nn-pdf" onClick={() => setPaying(r)} title="Pay it now — the Pay window opens filled in">Pay</button>
            )}
            <button type="button" className={`btn ${r.status === 'approved' ? 'btn-outline' : 'btn-primary'} btn-sm nn-pdf`} onClick={() => go(r, true)} title="Open the report full screen (PDF page) — then comment or approve" aria-label="Open the report full screen">
              <FileText size={16} /> View
            </button>
          </div>
        );
      })}
      {viewing && <WeeklyCash embed={{ id: viewing.id, branch: viewing.branch_id }} onEmbedClose={() => setViewing(null)} onEmbedSaved={() => { setViewing(null); onPaid?.(); }} />}
      {paying && <PayModal preset={{ kind: 'weekly_cash', branch: paying.branch_id, ref: paying.id }} onClose={() => setPaying(null)} onSaved={() => { setPaying(null); onPaid?.(); }} />}
    </div>
  );
}
