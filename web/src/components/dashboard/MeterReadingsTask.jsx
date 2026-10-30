import { useEffect, useState } from 'react';
import { Link } from 'react-router-dom';
import { Zap } from 'lucide-react';
import { supabase } from '../../lib/supabase';
import { useAuth } from '../../hooks/useAuth';
import { orgToday } from '../../lib/inventory';
import { ReadingsModal } from '../purchases/ElectricityPanel';
import { dateText } from '../../lib/format';

const units = v => new Intl.NumberFormat('en-US', { maximumFractionDigits: 2 }).format(v);

/*
 * Today's meter readings on the dashboard (2026-10-28), one row: each meter's
 * units left at its latest reading, what is still due today (morning, then
 * evening from 17:00), the readings window and the Electricity tab. Shown to
 * those who record readings at the branch (secretary, branch manager).
 */
export default function MeterReadingsTask({ branchId }) {
  const { organization, canAt } = useAuth();
  const today = orgToday(organization?.timezone);
  const [data, setData] = useState(null);
  const [open, setOpen] = useState(false);
  const can = !!branchId && (canAt('procurement.receive', branchId) || canAt('production.create', branchId));

  async function load() {
    if (!can) return;
    const [m, r] = await Promise.all([
      supabase.from('power_meters').select('id, name, meter_no, status').eq('branch_id', branchId).eq('status', 'active').order('name'),
      supabase.from('power_readings').select('*').eq('branch_id', branchId).eq('status', 'recorded').order('read_at', { ascending: false }).limit(60),
    ]);
    if (m.error) { setData(false); return; }
    setData({ meters: m.data || [], readings: r.data || [] });
  }
  useEffect(() => { setData(null); load(); }, [branchId, can]); // eslint-disable-line react-hooks/exhaustive-deps

  if (!can || data === false || (data && data.meters.length === 0)) return null;
  const hour = new Date().getHours();
  const got = (m, slot) => data?.readings.find(r => r.meter_id === m && r.read_on === today && r.slot === slot);
  const dueOf = m => [!got(m, 'morning') && 'morning', !got(m, 'evening') && hour >= 17 && 'evening'].filter(Boolean);
  const due = data ? data.meters.reduce((t, m) => t + dueOf(m.id).length, 0) : 0;

  return (
    <section className="card mb-24 mr-row" aria-label="Meter readings">
      <span className="mr-title"><Zap size={16} /> Meters</span>
      {data === null ? <span className="skeleton" style={{ flex: 1 }} /> : data.meters.map(m => {
        const last = data.readings.find(r => r.meter_id === m.id);
        const d = dueOf(m.id);
        return (
          <span key={m.id} className="mr-meter-inline" title={last ? `Latest reading: ${dateText(last.read_on)} ${last.slot}` : 'No reading yet'}>
            <strong>{m.name}</strong> {last ? `${units(Number(last.reading))} units left` : 'no reading yet'}
            {d.length > 0 ? <span className="mr-due"> · {d.join(' & ')} due</span> : <span className="mr-ok"> · today done</span>}
          </span>
        );
      })}
      <span className="mr-actions">
        {data && (due ? <span className="badge badge-warning">{due} due</span> : <span className="badge badge-success">Up to date</span>)}
        <Link to="/purchases?tab=electricity" className="btn btn-ghost btn-sm">Electricity ›</Link>
        <button type="button" className="btn btn-primary btn-sm" disabled={!data} onClick={() => setOpen(true)}>Record readings</button>
      </span>
      {open && <ReadingsModal meters={data.meters} readings={data.readings} today={today} onClose={() => setOpen(false)} onSaved={async () => { setOpen(false); await load(); }} />}
    </section>
  );
}
