import { useEffect, useMemo, useState } from 'react';
import { Users, Plus, FileText } from 'lucide-react';
import { supabase } from '../lib/supabase';
import { useUrlTab } from '../lib/urlTab';
import { useAuth } from '../hooks/useAuth';
import { useBranch } from '../hooks/useBranch';
import { formatMoney, formatAmount, dateText } from '../lib/format';
import { orgToday } from '../lib/inventory';
import { dbErrorMessage } from '../lib/masterData';
import { loadOwing, ageByBuyer, statementLines, owedSince, AGE_BUCKETS } from '../lib/receivables';
import PageShell from '../components/PageShell';
import { ListToolbar, PageTabs } from '../components/ListControls';
import EmptyState from '../components/EmptyState';
import ErrorState from '../components/ErrorState';
import Modal from '../components/Modal';
import LeadsPanel from '../components/customers/LeadsPanel';
import { useDefaultPaymentDays } from '../lib/paymentTerms';

const LOAD_ERROR = "We couldn't load customers. Please try again.";

/*
 * Customers (1e, migrations 064, 2026-10-27): shared by the organization's
 * branches — name, phone, TIN/VRN; who owes what and for how long (walk-in
 * buyers by name); each customer's history and statement of account.
 * Click shows the details; double-click or Edit changes them.
 */
export default function Customers() {
  const { organization, canAnywhere, can } = useAuth();
  const { branchId, inBranch } = useBranch();
  const money = v => formatMoney(v, organization?.currency_code);
  const today = orgToday(organization?.timezone);
  const [tab, setTab] = useUrlTab('customers');
  const [rows, setRows] = useState(null);
  const [sales, setSales] = useState([]);
  const [error, setError] = useState('');
  const [search, setSearch] = useState('');
  const [editing, setEditing] = useState(null);
  const [viewing, setViewing] = useState(null);
  const canEdit = (canAnywhere ?? can)('sales.create');

  async function load() {
    setError('');
    try {
      const [c, s] = await Promise.all([supabase.from('customers').select('*').order('name'), loadOwing()]);
      if (c.error) throw c.error;
      setRows(c.data || []);
      setSales(s);
    } catch (e) { console.error(e); setError(LOAD_ERROR); }
  }
  useEffect(() => { load(); }, []);

  // owed across the organization's branches for a customer; the "Who owes" list follows the branch picked
  const buyersAll = useMemo(() => ageByBuyer(sales, rows, today), [sales, rows, today]);
  const statsOf = id => buyersAll.find(b => b.key === id) ?? { owed: 0, sales: 0 };
  const owing = useMemo(() => {
    const q = search.trim().toLowerCase();
    return ageByBuyer(sales.filter(s => inBranch(s.branch_id)), rows, today)
      .filter(b => b.owed > 0 && (!q || `${b.name} ${b.phone ?? ''}`.toLowerCase().includes(q)))
      .sort((a, b) => b.owed - a.owed);
  }, [sales, rows, today, inBranch, search]);
  const shown = useMemo(() => {
    const q = search.trim().toLowerCase();
    return (rows || []).filter(c => !q || `${c.name} ${c.phone ?? ''} ${c.tin ?? ''}`.toLowerCase().includes(q));
  }, [rows, search]);
  const sum = (xs, f) => xs.reduce((t, x) => t + f(x), 0);

  return (
    <PageShell title="Customers" subtitle="Sales & Costing" description="Customers shared by every branch, what each owes and for how long, their history and statements."
      primaryAction={canEdit && tab === 'customers' && <button type="button" className="btn btn-primary" onClick={() => setEditing({})}><Plus size={15} /> New customer</button>}>
      <PageTabs tabs={[['customers', 'Customers'], ['leads', 'Leads'], ['owing', `Statements & aging${owing.length ? ` (${owing.length})` : ''}`]]} value={tab} onChange={setTab} />
      {error ? <div className="card"><ErrorState message={error} onRetry={load} /></div> : (
        <>
          {tab === 'leads' ? (
            <LeadsPanel branchId={branchId} inBranch={inBranch} today={today} currency={organization?.currency_code} search={search}
              toolbar={<ListToolbar id="leads-search" search={search} onSearch={setSearch} placeholder="Search name, contact, site or what they want…" />} />
          ) : <ListToolbar id="customers-search" search={search} onSearch={setSearch} placeholder="Search name, phone or TIN…" />}
          {tab === 'leads' ? null : tab === 'customers' ? (
            <section className="sk">
              <div className="sk-head"><span>Customers ({shown.length})</span></div>
              {rows === null ? Array.from({ length: 4 }).map((_, i) => <div key={i} className="sk-card"><span className="skeleton" /></div>)
              : shown.length === 0 ? <div className="card"><EmptyState icon={Users} title="No customers yet" description="Add them here or while making a sale. Walk-in buyers need no record." /></div>
              : shown.map(c => {
                const st = statsOf(c.id);
                return (
                  <div key={c.id} className={`sk-card lk-card${c.status !== 'active' ? ' is-inactive' : ''}`} onClick={() => setViewing(c)}
                    onDoubleClick={() => { if (canEdit) { setViewing(null); setEditing(c); } }} title="Click for details · double-click to edit">
                    <div className="sk-name">
                      <strong>{c.name}</strong>
                      <span className="pl-help">{[c.phone, c.tin && `TIN ${c.tin}`].filter(Boolean).join(' · ') || 'no phone'}</span>
                    </div>
                    <div className="sk-total">
                      <span><strong className={st.owed > 0 ? 'text-warning' : ''}>{money(st.owed)}</strong></span>
                      <span className="sk-sub">owed</span>
                    </div>
                    <div className="co-details">
                      <span>{st.sales} sale{st.sales === 1 ? '' : 's'}</span>
                      {st.oldest && <span className="pl-help">owed since {st.oldest}</span>}
                      {c.status !== 'active' && <span className="pl-help">not in use</span>}
                    </div>
                  </div>
                );
              })}
            </section>
          ) : (
            <div className="card"><div className="table-container">
              <table>
                <thead><tr><th>Customer</th><th>Phone</th>{AGE_BUCKETS.map(([, , l]) => <th key={l} className="num">{l} (TZS)</th>)}<th className="num">Owed (TZS)</th><th>Owed since</th><th>Last paid</th></tr></thead>
                <tbody>
                  {owing.length === 0 ? <tr><td colSpan={9} className="text-muted">{search ? 'Nobody matches.' : 'Nobody owes anything.'}</td></tr>
                  : owing.map(b => (
                    <tr key={b.key} className={b.customer ? 'clickable-row' : ''} onClick={() => b.customer && setViewing(b.customer)}>
                      <td><strong>{b.name}</strong>{!b.customer && <div className="pl-help">walk-in</div>}</td>
                      <td>{b.phone || ''}</td>
                      {b.buckets.map((v, i) => <td key={i} className={`num${i >= 2 && v > 0 ? ' text-warning' : ''}`}>{v ? formatAmount(v) : ''}</td>)}
                      <td className="num"><strong>{formatAmount(b.owed)}</strong></td>
                      <td>{b.oldest}</td>
                      <td>{b.lastPaid || <span className="pl-help">never</span>}</td>
                    </tr>
                  ))}
                </tbody>
                {owing.length > 0 && (
                  <tfoot><tr><td colSpan={2}><strong>Total</strong></td>
                    {AGE_BUCKETS.map((_, i) => <td key={i} className="num"><strong>{money(sum(owing, b => b.buckets[i]))}</strong></td>)}
                    <td className="num"><strong>{money(sum(owing, b => b.owed))}</strong></td><td colSpan={2} /></tr></tfoot>
                )}
              </table>
            </div></div>
          )}
        </>
      )}
      {viewing && <CustomerView customer={viewing} sales={sales.filter(s => s.customer_id === viewing.id)} stats={statsOf(viewing.id)} money={money} today={today}
        canEdit={canEdit} onEdit={() => { setEditing(viewing); setViewing(null); }} onClose={() => setViewing(null)} />}
      {editing && <CustomerModal customer={editing.id ? editing : null} organizationId={organization?.id} branchId={branchId}
        onClose={() => setEditing(null)} onSaved={async () => { setEditing(null); await load(); }} />}
    </PageShell>
  );
}

/* A customer: details, history (orders and invoices with what is paid), and their statement */
function CustomerView({ customer, sales, stats, money, today, canEdit, onEdit, onClose }) {
  const [from, setFrom] = useState(() => { const d = new Date(`${today}T00:00:00Z`); d.setUTCMonth(d.getUTCMonth() - 3); return d.toISOString().slice(0, 10); });
  const [to, setTo] = useState(today);
  const history = [...sales].sort((a, b) => (owedSince(a) < owedSince(b) ? 1 : -1));
  const st = statementLines(sales, null, today);
  const paidOf = s => (s.payments || []).reduce((t, p) => t + Number(p.amount), 0);
  const openStatement = () => window.open(`/print/statement/${customer.id}?from=${from}&to=${to}`, '_blank', 'noopener');
  return (
    <Modal title={customer.name} onClose={onClose} size="lg"
      footer={<>{canEdit && <button type="button" className="btn btn-outline" onClick={onEdit}>Edit</button>}
        <button type="button" className="btn btn-primary" onClick={onClose}>Close</button></>}>
      <dl className="detail-list text-sm">
        <dt>Phone</dt><dd>{customer.phone || '—'}</dd>
        <dt>Email</dt><dd>{customer.email || '—'}</dd>
        <dt>TIN / VRN</dt><dd>{[customer.tin, customer.vrn].filter(Boolean).join(' / ') || '—'}</dd>
        <dt>Address</dt><dd>{customer.address || '—'}</dd>
        <dt>Owed</dt><dd><strong className={stats.owed > 0 ? 'text-warning' : ''}>{money(stats.owed)}</strong>{stats.oldest ? ` — since ${stats.oldest}` : ''} · bought {money(st.charged)}, paid {money(st.paid)} in all</dd>
        {customer.notes && <><dt>Notes</dt><dd>{customer.notes}</dd></>}
      </dl>

      <h3 className="modal-section-title">Statement of account</h3>
      <div className="flex items-center gap-8" style={{ flexWrap: 'wrap' }}>
        <label className="pe-field"><span>From</span><input type="date" className="form-input" max={to} value={from} onChange={e => setFrom(e.target.value)} /></label>
        <label className="pe-field"><span>To</span><input type="date" className="form-input" max={today} value={to} onChange={e => setTo(e.target.value)} /></label>
        <button type="button" className="btn btn-outline btn-sm" style={{ alignSelf: 'flex-end' }} onClick={openStatement}><FileText size={14} /> Statement</button>
      </div>

      <h3 className="modal-section-title">History</h3>
      <div className="table-container">
        <table>
          <thead><tr><th>Date</th><th>Sale</th><th className="num">Total (TZS)</th><th className="num">Paid (TZS)</th><th className="num">Balance (TZS)</th><th>Payments</th></tr></thead>
          <tbody>
            {history.length === 0 ? <tr><td colSpan={6} className="text-muted">No orders or invoices yet.</td></tr>
            : history.map(s => (
              <tr key={s.id} className="clickable-row" onClick={() => window.open(`/print/sale/${s.id}?doc=${s.stage === 'invoice' ? 'invoice' : 'proforma'}`, '_blank', 'noopener')} title="Open the document">
                <td>{owedSince(s)}</td>
                <td>{s.stage === 'invoice' ? 'Invoice' : 'Order'} #{s.sale_no}</td>
                <td className="num">{formatAmount(Number(s.total))}</td>
                <td className="num">{formatAmount(paidOf(s))}</td>
                <td className={`num${Number(s.total) - paidOf(s) > 0.004 ? ' text-warning' : ''}`}><strong>{formatAmount(Number(s.total) - paidOf(s))}</strong></td>
                <td className="pl-help">{(s.payments || []).sort((a, b) => (a.paid_on < b.paid_on ? -1 : 1)).map(p => `${dateText(p.paid_on)}: ${formatAmount(Number(p.amount))}`).join(' · ')}</td>
              </tr>
            ))}
          </tbody>
        </table>
      </div>
    </Modal>
  );
}

function CustomerModal({ customer, organizationId, branchId, onClose, onSaved }) {
  const { organization } = useAuth();
  const [usualDays] = useDefaultPaymentDays(organization?.id);
  const hasTerms = usualDays != null;   // 097
  const [f, setF] = useState({ payment_days: customer?.payment_days != null ? String(customer.payment_days) : '', name: customer?.name ?? '', phone: customer?.phone ?? '', email: customer?.email ?? '', tin: customer?.tin ?? '',
    vrn: customer?.vrn ?? '', address: customer?.address ?? '', notes: customer?.notes ?? '', status: customer?.status ?? 'active' });
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState('');
  const field = (k, label, extra = {}) => (
    <label className="pe-field"><span>{label}</span><input className="form-input" value={f[k]} onChange={e => setF({ ...f, [k]: e.target.value })} {...extra} /></label>
  );
  async function save() {
    setError('');
    if (!f.name.trim()) { setError('Enter the name.'); return; }
    const row = Object.fromEntries(Object.entries(f).map(([k, v]) => [k, typeof v === 'string' && k !== 'status' ? (v.trim() || null) : v]));
    if (!hasTerms) delete row.payment_days;
    else if (row.payment_days != null && !(Number(row.payment_days) >= 0 && Number(row.payment_days) <= 365)) { setError('Payment days: 0 to 365, or empty for the usual.'); return; }
    setBusy(true);
    const { error: err } = customer
      ? await supabase.from('customers').update(row).eq('id', customer.id)
      : await supabase.from('customers').insert({ ...row, organization_id: organizationId, branch_id: branchId || null });
    setBusy(false);
    if (err) { setError(dbErrorMessage(err)); return; }
    onSaved();
  }
  return (
    <Modal title={customer ? `Edit ${customer.name}` : 'New customer'} onClose={onClose}
      footer={<>{error && <span className="modal-footer-error" role="alert">{error}</span>}
        <button type="button" className="btn btn-outline" onClick={onClose}>Cancel</button>
        <button type="button" className={`btn btn-primary${busy ? ' btn-loading' : ''}`} disabled={busy} onClick={save}>Save</button></>}>
      <div className="modal-form">
        {field('name', 'Name', { autoFocus: true })}
        <div className="form-row">{field('phone', 'Phone', { inputMode: 'tel' })}{field('email', 'Email')}</div>
        <div className="form-row">{field('tin', 'TIN')}{field('vrn', 'VRN')}{hasTerms && field('payment_days', `Payment days (usual ${usualDays})`, { inputMode: 'numeric', placeholder: 'usual' })}</div>
        {field('address', 'Address')}
        {field('notes', 'Notes')}
        {customer && <label className="text-sm flex items-center gap-8"><input type="checkbox" checked={f.status === 'active'} onChange={e => setF({ ...f, status: e.target.checked ? 'active' : 'inactive' })} /> In use</label>}
      </div>
    </Modal>
  );
}
