import { useEffect, useState } from 'react';
import { Link } from 'react-router-dom';
import { Zap, Check } from 'lucide-react';
import { supabase } from '../../lib/supabase';
import { useAuth } from '../../hooks/useAuth';
import { orgToday } from '../../lib/inventory';
import { ReadingsModal } from '../purchases/ElectricityPanel';

const units = v => new Intl.NumberFormat('en-US', { maximumFractionDigits: 2 }).format(v);

/*
 * Today's meter readings on the dashboard (2026-10-28): a job done every
 * morning (asubuhi) and evening (jioni) by the secretary or branch manager —
 * each meter's two readings, done or still due, and the same readings window
 * as Purchases › Electricity. Shown to those who record readings at the branch.
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
      supabase.from('power_readings').select('*').eq('branch_id', branchId).eq('status', 'recorded').gte('read_on', today).order('read_at'),
    ]);
    if (m.error) { setData(false); return; }
    setData({ meters: m.data || [], readings: r.data || [] });
  }
  useEffect(() => { setData(null); load(); }, [branchId, can]); // eslint-disable-line react-hooks/exhaustive-deps

  if (!can || data === false || (data && data.meters.length === 0)) return null;
  const hour = new Date().getHours();
  const got = (m, slot) => data?.readings.find(r => r.meter_id === m && r.read_on === today && r.slot === slot);
  const due = data ? data.meters.flatMap(m => [!got(m.id, 'morning') && 'morning', !got(m.id, 'evening') && hour >= 17 && 'evening'].filter(Boolean)).length : 0;

  return (
    <section className="card mb-24 mr-task" aria-label="Today's meter readings">
      <div className="card-header" style={{ gap: 8 }}>
        <h2 className="card-title"><Zap size={16} /> Meter readings today</h2>
        {data && (due ? <span className="badge badge-warning">{due} due</span> : <span className="badge badge-success">Up to date</span>)}
        <span style={{ marginLeft: 'auto' }} className="flex items-center gap-8">
          <Link to="/purchases?tab=electricity" className="btn btn-ghost btn-sm">Electricity ›</Link>
          <button type="button" className="btn btn-primary btn-sm" disabled={!data} onClick={() => setOpen(true)}>Record readings</button>
        </span>
      </div>
      <div className="card-body mr-grid">
        {data === null ? <span className="skeleton" /> : data.meters.map(m => (
          <div key={m.id} className="mr-meter">
            <strong>{m.name}</strong>
            {['morning', 'evening'].map(slot => {
              const r = got(m.id, slot);
              return (
                <span key={slot} className={`mr-slot${r ? ' is-done' : slot === 'morning' || hour >= 17 ? ' is-due' : ''}`}>
                  {slot === 'morning' ? 'Morning' : 'Evening'}: {r ? <><Check size={12} /> {units(Number(r.reading))}</> : slot === 'evening' && hour < 17 ? 'later' : 'due'}
                </span>
              );
            })}
          </div>
        ))}
      </div>
      {open && <ReadingsModal meters={data.meters} readings={data.readings} today={today} onClose={() => setOpen(false)} onSaved={async () => { setOpen(false); await load(); }} />}
    </section>
  );
}
