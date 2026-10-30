import { useState } from 'react';
import { Printer, Boxes, DollarSign, CalendarCheck, ShoppingCart } from 'lucide-react';
import { useAuth } from '../hooks/useAuth';
import { useBranch } from '../hooks/useBranch';
import { orgToday } from '../lib/inventory';
import PageShell from '../components/PageShell';

const LISTS = [
  { kind: 'stock', label: 'Stock list', icon: Boxes, perm: 'inventory.view', text: 'Every product (by colour) and material in the branch stores, with the quantity on hand — for a stock count or the notice board.' },
  { kind: 'prices', label: 'Price list', icon: DollarSign, perm: 'products.view', text: 'The branch’s selling prices with VAT, per piece or per m² as each product is sold — to hand to customers.' },
  { kind: 'attendance', label: 'Attendance sheet', icon: CalendarCheck, perm: 'staff.view', dated: true, text: 'Who worked each day of the period, person by person, with the days worked.' },
  { kind: 'purchases', label: 'Purchase record', icon: ShoppingCart, perm: 'procurement.view', dated: true, text: 'Every purchase in the period: supplier, invoice, total, paid and still to pay.' },
];

/*
 * Print lists (Document Center, 2026-10-30): A4 lists of the branch in the
 * sidebar, each opening in a tab of its own to print or save as PDF
 * (/print/list/:kind?branch=&from=&to= — ListDocument).
 */
export default function PrintLists() {
  const { can, organization } = useAuth();
  const { branchId, branchName } = useBranch();
  const today = orgToday(organization?.timezone);
  const [range, setRange] = useState([`${today.slice(0, 7)}-01`, today]);
  const [from, to] = range;
  const lists = LISTS.filter(l => can(l.perm));
  const open = l => window.open(`/print/list/${l.kind}?branch=${branchId}${l.dated ? `&from=${from}&to=${to}` : ''}`, '_blank', 'noopener');

  return (
    <PageShell title="Print lists" subtitle="Document Center"
      description={branchId ? `Lists of ${branchName} to print or save as PDF.` : 'Pick a branch in the sidebar — each list is for one branch.'}>
      <div className="flex items-center gap-8" style={{ marginBottom: 12, flexWrap: 'wrap' }}>
        <span className="pl-label">Period for dated lists</span>
        <input type="date" className="form-input" style={{ width: 160 }} aria-label="From" max={to} value={from} onChange={e => setRange([e.target.value || from, to])} />
        <span className="pl-help">to</span>
        <input type="date" className="form-input" style={{ width: 160 }} aria-label="To" min={from} max={today} value={to} onChange={e => setRange([from, e.target.value || to])} />
      </div>
      <div className="pls-grid">
        {lists.map(l => (
          <div key={l.kind} className="card pls-card">
            <div className="pls-head"><l.icon size={18} /><strong>{l.label}</strong></div>
            <p className="pl-help">{l.text}</p>
            <div className="pls-foot">
              <span className="pl-help">{l.dated ? `${from} to ${to}` : 'as of today'}</span>
              <button type="button" className="btn btn-primary btn-sm" disabled={!branchId} title={branchId ? '' : 'Pick a branch first'} onClick={() => open(l)}><Printer size={13} /> Open to print</button>
            </div>
          </div>
        ))}
        {lists.length === 0 && <p className="pl-help">Your role doesn&apos;t open any of these lists.</p>}
      </div>
    </PageShell>
  );
}
