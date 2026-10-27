-- ============================================================
-- 072 — Electricity (LUKU) by meter (1e, full production cost)
--
-- SwahziTech, 2026-10-27: LUKU is bought 2–3 times a month (an Electricity
-- expense, with the meter and units) and used daily (the units left on each
-- meter, read in the daily report — its screen comes later). Like cement:
-- bought in lumps, used daily, priced oldest token first.
--
-- Each meter is either all production, or split by the high-low method: a
-- baseline of units a day is the office/period share, and whatever the day
-- used above it is direct production. Meters are kept with Expenses (⚙).
--
--   units used between two readings = earlier reading + tokens loaded in
--                                     between − this reading
--   cost = those units, oldest token first (the units on the meter at its
--          first reading are priced at the token loaded before it, else the
--          first token)
--   baseline meter: period units = least(used, baseline × days covered);
--                   production units = the rest
--
-- The production cost is shared over the day's batches on the meter's
-- machines in 073. The tenant's meters and baseline are entered in the app.
-- ============================================================

-- ------------------------------------------------------------
-- 1. Meters and the machines they feed
-- ------------------------------------------------------------
CREATE TABLE public.power_meters (
  id               uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  organization_id  uuid NOT NULL REFERENCES public.organizations(id) ON DELETE CASCADE,
  branch_id        uuid NOT NULL REFERENCES public.branches(id) ON DELETE RESTRICT,
  name             text NOT NULL CHECK (btrim(name) <> ''),
  meter_no         text,                                                   -- the LUKU meter number
  split_mode       text NOT NULL DEFAULT 'production' CHECK (split_mode IN ('production', 'baseline')),
  baseline_units_per_day numeric CHECK (baseline_units_per_day >= 0),     -- high-low: the office/period units a day
  status           text NOT NULL DEFAULT 'active' CHECK (status IN ('active', 'inactive')),
  created_at       timestamptz NOT NULL DEFAULT now(),
  updated_at       timestamptz NOT NULL DEFAULT now()
);
CREATE UNIQUE INDEX uq_power_meters_name ON public.power_meters (branch_id, public.normalize_name(name));
COMMENT ON COLUMN public.power_meters.split_mode IS 'production = every unit is direct production; baseline = high-low: baseline_units_per_day is the office/period share, units above it production (072).';
CREATE TRIGGER trg_power_meters_updated_at BEFORE UPDATE ON public.power_meters FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();
CREATE TRIGGER trg_power_meters_audit AFTER INSERT OR UPDATE OR DELETE ON public.power_meters FOR EACH ROW EXECUTE FUNCTION public.audit_row_change('power_meter', 'id');
CREATE TRIGGER trg_power_meters_no_delete BEFORE DELETE ON public.power_meters FOR EACH ROW EXECUTE FUNCTION public.prevent_hard_delete('meter');
ALTER TABLE public.power_meters ENABLE ROW LEVEL SECURITY;
CREATE POLICY "power_meters: read own org" ON public.power_meters FOR SELECT USING (organization_id = public.get_my_org_id());
-- kept by those who record expenses or keep the production lists
CREATE FUNCTION public.can_keep_meters(p_branch_id uuid)
RETURNS boolean LANGUAGE sql STABLE SECURITY INVOKER SET search_path = public AS $$
  SELECT public.has_permission_at('procurement.receive', p_branch_id, NULL) OR public.can_keep_production_lists(p_branch_id)
$$;
CREATE POLICY "power_meters: branch adds" ON public.power_meters FOR INSERT
  WITH CHECK (organization_id = public.get_my_org_id() AND public.can_keep_meters(branch_id));
CREATE POLICY "power_meters: branch changes" ON public.power_meters FOR UPDATE
  USING (organization_id = public.get_my_org_id() AND public.can_keep_meters(branch_id))
  WITH CHECK (organization_id = public.get_my_org_id() AND public.can_keep_meters(branch_id));

CREATE TABLE public.power_meter_machines (
  meter_id        uuid NOT NULL REFERENCES public.power_meters(id) ON DELETE CASCADE,
  machine_id      uuid NOT NULL REFERENCES public.machines(id) ON DELETE CASCADE,
  organization_id uuid NOT NULL REFERENCES public.organizations(id) ON DELETE CASCADE,
  PRIMARY KEY (meter_id, machine_id)
);
CREATE UNIQUE INDEX uq_power_meter_machines_machine ON public.power_meter_machines (machine_id);   -- a machine is on one meter
ALTER TABLE public.power_meter_machines ENABLE ROW LEVEL SECURITY;
CREATE POLICY "power_meter_machines: read own org" ON public.power_meter_machines FOR SELECT USING (organization_id = public.get_my_org_id());
CREATE POLICY "power_meter_machines: branch adds" ON public.power_meter_machines FOR INSERT
  WITH CHECK (organization_id = public.get_my_org_id()
              AND EXISTS (SELECT 1 FROM public.power_meters m JOIN public.machines x ON x.id = machine_id AND x.branch_id = m.branch_id
                          WHERE m.id = meter_id AND public.can_keep_meters(m.branch_id)));
CREATE POLICY "power_meter_machines: branch removes" ON public.power_meter_machines FOR DELETE
  USING (organization_id = public.get_my_org_id()
         AND EXISTS (SELECT 1 FROM public.power_meters m WHERE m.id = meter_id AND public.can_keep_meters(m.branch_id)));

-- ------------------------------------------------------------
-- 2. Tokens loaded and readings taken (written through the functions below)
-- ------------------------------------------------------------
CREATE TABLE public.power_tokens (
  id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  organization_id uuid NOT NULL REFERENCES public.organizations(id) ON DELETE CASCADE,
  branch_id       uuid NOT NULL REFERENCES public.branches(id) ON DELETE RESTRICT,
  meter_id        uuid NOT NULL REFERENCES public.power_meters(id) ON DELETE RESTRICT,
  loaded_at       timestamptz NOT NULL,
  units           numeric NOT NULL CHECK (units > 0),          -- kWh bought
  amount          numeric NOT NULL CHECK (amount >= 0),        -- what was paid
  token_no        text,
  expense_id      uuid REFERENCES public.expenses(id) ON DELETE RESTRICT,   -- the Electricity expense it made
  status          text NOT NULL DEFAULT 'recorded' CHECK (status IN ('recorded', 'void')),
  void_reason     text,
  created_by      uuid REFERENCES auth.users(id) ON DELETE SET NULL,
  created_at      timestamptz NOT NULL DEFAULT now(),
  CHECK ((status = 'void') = (void_reason IS NOT NULL))
);
CREATE INDEX idx_power_tokens_meter ON public.power_tokens (meter_id, loaded_at);
CREATE TRIGGER trg_power_tokens_audit AFTER INSERT OR UPDATE OR DELETE ON public.power_tokens FOR EACH ROW EXECUTE FUNCTION public.audit_row_change('power_token', 'id');
CREATE TRIGGER trg_power_tokens_no_delete BEFORE DELETE ON public.power_tokens FOR EACH ROW EXECUTE FUNCTION public.prevent_hard_delete('token');
ALTER TABLE public.power_tokens ENABLE ROW LEVEL SECURITY;
CREATE POLICY "power_tokens: read own org" ON public.power_tokens FOR SELECT USING (organization_id = public.get_my_org_id());

CREATE TABLE public.power_readings (
  id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  organization_id uuid NOT NULL REFERENCES public.organizations(id) ON DELETE CASCADE,
  branch_id       uuid NOT NULL REFERENCES public.branches(id) ON DELETE RESTRICT,
  meter_id        uuid NOT NULL REFERENCES public.power_meters(id) ON DELETE RESTRICT,
  read_at         timestamptz NOT NULL,
  reading         numeric NOT NULL CHECK (reading >= 0),       -- units left on the meter
  note            text,
  status          text NOT NULL DEFAULT 'recorded' CHECK (status IN ('recorded', 'void')),
  void_reason     text,
  created_by      uuid REFERENCES auth.users(id) ON DELETE SET NULL,
  created_at      timestamptz NOT NULL DEFAULT now(),
  CHECK ((status = 'void') = (void_reason IS NOT NULL))
);
CREATE UNIQUE INDEX uq_power_readings_time ON public.power_readings (meter_id, read_at) WHERE status = 'recorded';
CREATE TRIGGER trg_power_readings_audit AFTER INSERT OR UPDATE OR DELETE ON public.power_readings FOR EACH ROW EXECUTE FUNCTION public.audit_row_change('power_reading', 'id');
CREATE TRIGGER trg_power_readings_no_delete BEFORE DELETE ON public.power_readings FOR EACH ROW EXECUTE FUNCTION public.prevent_hard_delete('reading');
ALTER TABLE public.power_readings ENABLE ROW LEVEL SECURITY;
CREATE POLICY "power_readings: read own org" ON public.power_readings FOR SELECT USING (organization_id = public.get_my_org_id());

-- ------------------------------------------------------------
-- 3. Use between readings, oldest token first
-- ------------------------------------------------------------
-- The cost of the first p_units units a meter used since its first reading:
-- layers are the units on it at that reading, then each token loaded after it
CREATE FUNCTION public.power_fifo_cost(p_meter uuid, p_units numeric)
RETURNS numeric
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public
AS $$
DECLARE
  first_r record;
  open_price numeric;
  left_u numeric := greatest(coalesce(p_units, 0), 0);
  total numeric := 0;
  take numeric;
  k record;
BEGIN
  IF left_u = 0 THEN RETURN 0; END IF;
  SELECT read_at, reading INTO first_r FROM public.power_readings WHERE meter_id = p_meter AND status = 'recorded' ORDER BY read_at LIMIT 1;
  IF NOT FOUND THEN RETURN NULL; END IF;
  -- the units already on the meter: the token loaded before the first reading, else the first token
  SELECT amount / units INTO open_price FROM public.power_tokens WHERE meter_id = p_meter AND status = 'recorded' AND loaded_at <= first_r.read_at ORDER BY loaded_at DESC LIMIT 1;
  IF open_price IS NULL THEN
    SELECT amount / units INTO open_price FROM public.power_tokens WHERE meter_id = p_meter AND status = 'recorded' ORDER BY loaded_at LIMIT 1;
  END IF;
  take := least(left_u, first_r.reading);
  IF take > 0 THEN
    IF open_price IS NULL THEN RETURN NULL; END IF;
    total := total + take * open_price; left_u := left_u - take;
  END IF;
  FOR k IN SELECT units, amount FROM public.power_tokens WHERE meter_id = p_meter AND status = 'recorded' AND loaded_at > first_r.read_at ORDER BY loaded_at, created_at LOOP
    EXIT WHEN left_u <= 0;
    take := least(left_u, k.units);
    total := total + take * k.amount / k.units; left_u := left_u - take;
  END LOOP;
  IF left_u > 0.0001 THEN RETURN NULL; END IF;   -- more used than was ever on the meter
  RETURN total;
END;
$$;
REVOKE ALL ON FUNCTION public.power_fifo_cost(uuid, numeric) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.power_fifo_cost(uuid, numeric) TO authenticated;

CREATE OR REPLACE VIEW public.power_use WITH (security_invoker = true) AS
WITH r AS (
  SELECT r.id AS reading_id, r.organization_id, r.branch_id, r.meter_id, m.name AS meter_name, m.split_mode, m.baseline_units_per_day,
         p.read_at AS from_at, r.read_at AS to_at,
         (p.read_at AT TIME ZONE coalesce(o.timezone, 'UTC'))::date AS from_day,
         (r.read_at AT TIME ZONE coalesce(o.timezone, 'UTC'))::date AS day,
         p.reading AS from_reading, r.reading AS to_reading, t.loaded AS units_loaded,
         p.reading + t.loaded - r.reading AS units_used,
         -- units used since the first reading, before and after this stretch
         f.reading + tc.loaded_before - p.reading AS used_before,
         f.reading + tc.loaded_before + t.loaded - r.reading AS used_after
  FROM public.power_readings r
  JOIN public.power_meters m ON m.id = r.meter_id
  JOIN public.organizations o ON o.id = r.organization_id
  JOIN LATERAL (SELECT read_at, reading FROM public.power_readings x
                WHERE x.meter_id = r.meter_id AND x.status = 'recorded' AND x.read_at < r.read_at
                ORDER BY x.read_at DESC LIMIT 1) p ON true
  JOIN LATERAL (SELECT read_at, reading FROM public.power_readings x
                WHERE x.meter_id = r.meter_id AND x.status = 'recorded' ORDER BY x.read_at LIMIT 1) f ON true
  CROSS JOIN LATERAL (SELECT coalesce(sum(units), 0) AS loaded FROM public.power_tokens k
                      WHERE k.meter_id = r.meter_id AND k.status = 'recorded' AND k.loaded_at > p.read_at AND k.loaded_at <= r.read_at) t
  CROSS JOIN LATERAL (SELECT coalesce(sum(units), 0) AS loaded_before FROM public.power_tokens k
                      WHERE k.meter_id = r.meter_id AND k.status = 'recorded' AND k.loaded_at > f.read_at AND k.loaded_at <= p.read_at) tc
  WHERE r.status = 'recorded'
), c AS (
  SELECT r.*, greatest(r.day - r.from_day, 1) AS days,
         round(public.power_fifo_cost(r.meter_id, r.used_after) - public.power_fifo_cost(r.meter_id, r.used_before), 2) AS cost,
         CASE WHEN r.split_mode = 'baseline' THEN least(r.units_used, coalesce(r.baseline_units_per_day, 0) * greatest(r.day - r.from_day, 1)) ELSE 0 END AS period_units
  FROM r
)
SELECT reading_id, organization_id, branch_id, meter_id, meter_name, split_mode, from_at, to_at, from_day, day, days,
       from_reading, units_loaded, to_reading, units_used,
       CASE WHEN units_used > 0 THEN round(cost / units_used, 4) END AS price_per_unit,
       cost,
       period_units,
       units_used - period_units AS production_units,
       CASE WHEN units_used > 0 THEN round(cost * (units_used - period_units) / units_used, 2) ELSE 0 END AS production_cost
FROM c;
COMMENT ON VIEW public.power_use IS 'Electricity used on a meter between a reading and the one before it: oldest token first; production units above the baseline (072).';
GRANT SELECT ON public.power_use TO authenticated;

-- ------------------------------------------------------------
-- 4. Record a reading — p: { meter_id, reading, read_at?, note? }
--    refused when it is more than the meter could hold (a token left out?)
-- ------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.record_power_reading(p jsonb)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  m    public.power_meters;
  at   timestamptz := coalesce(nullif(p->>'read_at', '')::timestamptz, now());
  val  numeric := nullif(p->>'reading', '')::numeric;
  prev record;
  nxt  record;
  ld   numeric;
  rid  uuid;
BEGIN
  SELECT * INTO m FROM public.power_meters WHERE id = (p->>'meter_id')::uuid AND organization_id = public.get_my_org_id();
  IF NOT FOUND THEN RAISE EXCEPTION 'Meter not found' USING ERRCODE = '23514'; END IF;
  IF NOT public.has_permission_at('production.create', m.branch_id, NULL) THEN RAISE EXCEPTION 'You can''t record meter readings at this branch' USING ERRCODE = '42501'; END IF;
  IF val IS NULL OR val < 0 THEN RAISE EXCEPTION 'Enter the units left on the meter' USING ERRCODE = '23514'; END IF;
  IF at > now() + interval '5 minutes' THEN RAISE EXCEPTION 'The time can''t be in the future' USING ERRCODE = '23514'; END IF;
  IF EXISTS (SELECT 1 FROM public.power_readings WHERE meter_id = m.id AND read_at = at AND status = 'recorded') THEN
    RAISE EXCEPTION 'There is already a reading at that time' USING ERRCODE = '23514';
  END IF;
  -- never more units than the meter held before plus what was loaded since
  SELECT read_at, reading INTO prev FROM public.power_readings WHERE meter_id = m.id AND status = 'recorded' AND read_at < at ORDER BY read_at DESC LIMIT 1;
  IF FOUND THEN
    SELECT coalesce(sum(units), 0) INTO ld FROM public.power_tokens WHERE meter_id = m.id AND status = 'recorded' AND loaded_at > prev.read_at AND loaded_at <= at;
    IF val > prev.reading + ld + 0.0001 THEN
      RAISE EXCEPTION 'That is more than the meter could hold (% before, % loaded since) — record the token first', prev.reading, ld USING ERRCODE = '23514';
    END IF;
  END IF;
  SELECT read_at, reading INTO nxt FROM public.power_readings WHERE meter_id = m.id AND status = 'recorded' AND read_at > at ORDER BY read_at LIMIT 1;
  IF FOUND THEN
    SELECT coalesce(sum(units), 0) INTO ld FROM public.power_tokens WHERE meter_id = m.id AND status = 'recorded' AND loaded_at > at AND loaded_at <= nxt.read_at;
    IF nxt.reading > val + ld + 0.0001 THEN
      RAISE EXCEPTION 'That is less than the reading after it allows (% at %)', nxt.reading, nxt.read_at USING ERRCODE = '23514';
    END IF;
  END IF;
  INSERT INTO public.power_readings (organization_id, branch_id, meter_id, read_at, reading, note, created_by)
  VALUES (m.organization_id, m.branch_id, m.id, at, val, nullif(btrim(p->>'note'), ''), auth.uid())
  RETURNING id INTO rid;
  RETURN rid;
END;
$$;

CREATE OR REPLACE FUNCTION public.void_power_reading(p_id uuid, p_reason text)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  r public.power_readings;
BEGIN
  SELECT * INTO r FROM public.power_readings WHERE id = p_id AND organization_id = public.get_my_org_id() FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Reading not found' USING ERRCODE = '23514'; END IF;
  IF NOT public.has_permission_at('production.create', r.branch_id, NULL) THEN RAISE EXCEPTION 'You can''t change meter readings at this branch' USING ERRCODE = '42501'; END IF;
  IF r.status = 'void' THEN RAISE EXCEPTION 'Already void' USING ERRCODE = '23514'; END IF;
  IF nullif(btrim(p_reason), '') IS NULL THEN RAISE EXCEPTION 'Give the reason' USING ERRCODE = '23514'; END IF;
  UPDATE public.power_readings SET status = 'void', void_reason = btrim(p_reason) WHERE id = r.id;
END;
$$;

-- ------------------------------------------------------------
-- 5. Load a token — p: { meter_id, units, amount, loaded_at?, token_no?, paid_from? (payment method) }
--    also recorded as an Electricity expense (paid)
-- ------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.record_power_token(p jsonb)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  m   public.power_meters;
  at  timestamptz := coalesce(nullif(p->>'loaded_at', '')::timestamptz, now());
  un  numeric := nullif(p->>'units', '')::numeric;
  amt numeric := round(nullif(p->>'amount', '')::numeric, 2);
  cat uuid;
  eid uuid;
  tid uuid;
  dt  date;
BEGIN
  SELECT * INTO m FROM public.power_meters WHERE id = (p->>'meter_id')::uuid AND organization_id = public.get_my_org_id();
  IF NOT FOUND THEN RAISE EXCEPTION 'Meter not found' USING ERRCODE = '23514'; END IF;
  IF NOT (public.has_permission_at('production.create', m.branch_id, NULL) OR public.has_permission_at('procurement.receive', m.branch_id, NULL)) THEN
    RAISE EXCEPTION 'You can''t record tokens at this branch' USING ERRCODE = '42501';
  END IF;
  IF un IS NULL OR un <= 0 THEN RAISE EXCEPTION 'Enter the units bought' USING ERRCODE = '23514'; END IF;
  IF amt IS NULL OR amt < 0 THEN RAISE EXCEPTION 'Enter what was paid' USING ERRCODE = '23514'; END IF;
  IF at > now() + interval '5 minutes' THEN RAISE EXCEPTION 'The time can''t be in the future' USING ERRCODE = '23514'; END IF;
  -- a token before a later reading would change that reading's use: it must still fit
  IF EXISTS (SELECT 1 FROM public.power_readings WHERE meter_id = m.id AND status = 'recorded' AND read_at >= at) THEN
    RAISE EXCEPTION 'There are readings after that time — load the token at its real time, or void the later readings first' USING ERRCODE = '23514';
  END IF;
  dt := (at AT TIME ZONE coalesce((SELECT timezone FROM public.organizations WHERE id = m.organization_id), 'UTC'))::date;
  SELECT id INTO cat FROM public.expense_categories WHERE organization_id = m.organization_id AND public.normalize_name(name) = public.normalize_name('Electricity');
  IF cat IS NULL THEN
    INSERT INTO public.expense_categories (organization_id, name) VALUES (m.organization_id, 'Electricity') RETURNING id INTO cat;
  END IF;
  INSERT INTO public.expenses (organization_id, branch_id, expense_date, category_id, description, quantity, unit_price, amount, amount_paid,
                               payment_method, paid_on, notes, created_by)
  VALUES (m.organization_id, m.branch_id, dt, cat, 'LUKU token — ' || m.name, un, round(amt / un, 4), amt, amt,
          coalesce(nullif(btrim(p->>'paid_from'), ''), 'cash'), dt, nullif(btrim(p->>'token_no'), ''), auth.uid())
  RETURNING id INTO eid;
  INSERT INTO public.power_tokens (organization_id, branch_id, meter_id, loaded_at, units, amount, token_no, expense_id, created_by)
  VALUES (m.organization_id, m.branch_id, m.id, at, un, amt, nullif(btrim(p->>'token_no'), ''), eid, auth.uid())
  RETURNING id INTO tid;
  RETURN tid;
END;
$$;

CREATE OR REPLACE FUNCTION public.void_power_token(p_id uuid, p_reason text)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  k public.power_tokens;
BEGIN
  SELECT * INTO k FROM public.power_tokens WHERE id = p_id AND organization_id = public.get_my_org_id() FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Token not found' USING ERRCODE = '23514'; END IF;
  IF NOT (public.has_permission_at('production.create', k.branch_id, NULL) OR public.has_permission_at('procurement.receive', k.branch_id, NULL)) THEN
    RAISE EXCEPTION 'You can''t change tokens at this branch' USING ERRCODE = '42501';
  END IF;
  IF k.status = 'void' THEN RAISE EXCEPTION 'Already void' USING ERRCODE = '23514'; END IF;
  IF nullif(btrim(p_reason), '') IS NULL THEN RAISE EXCEPTION 'Give the reason' USING ERRCODE = '23514'; END IF;
  IF EXISTS (SELECT 1 FROM public.power_readings WHERE meter_id = k.meter_id AND status = 'recorded' AND read_at >= k.loaded_at) THEN
    RAISE EXCEPTION 'Readings after it count this token — void those readings first' USING ERRCODE = '23514';
  END IF;
  UPDATE public.power_tokens SET status = 'void', void_reason = btrim(p_reason) WHERE id = k.id;
  IF k.expense_id IS NOT NULL THEN
    UPDATE public.expenses SET status = 'void', void_reason = 'Token voided: ' || btrim(p_reason) WHERE id = k.expense_id;
  END IF;
END;
$$;

REVOKE ALL ON FUNCTION public.record_power_reading(jsonb), public.void_power_reading(uuid, text),
  public.record_power_token(jsonb), public.void_power_token(uuid, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.record_power_reading(jsonb), public.void_power_reading(uuid, text),
  public.record_power_token(jsonb), public.void_power_token(uuid, text) TO authenticated;
