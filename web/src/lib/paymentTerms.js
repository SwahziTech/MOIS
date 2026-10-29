import { useEffect, useState } from 'react';
import { supabase } from './supabase';

/**
 * The company's usual payment days (097) → a number, null while loading,
 * or undefined when the system doesn't have payment terms yet.
 */
export function useDefaultPaymentDays(orgId) {
  const [days, setDays] = useState(null);
  async function load() {
    if (!orgId) return;
    const { data, error } = await supabase.from('organizations').select('default_payment_days').eq('id', orgId).maybeSingle();
    setDays(error ? undefined : Number(data?.default_payment_days ?? 0));
  }
  useEffect(() => { load(); }, [orgId]); // eslint-disable-line react-hooks/exhaustive-deps
  return [days, load];
}
