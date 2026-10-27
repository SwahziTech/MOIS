-- ============================================================
-- 072 — Electricity (LUKU) by meter (1e, full production cost — part 2)
--
-- SwahziTech, 2026-10-27, the user: electricity units are counted daily on
-- each meter; a meter feeds one or more production machines/zones, and some
-- of it may go to the office (not production). Each branch keeps its meters
-- (which machines each one feeds, and the share used by the office); token
-- purchases (units and price — each also recorded as an Electricity expense)
-- and readings of the units left on the meter.
--
--   units used between two readings = earlier reading + tokens loaded in
--                                     between − this reading
--   price per unit = the latest token loaded by then (amount ÷ units)
--   production share = units used × (100 − office %) / 100
--
-- Shared over that day's batches on the meter's machines in the costing step.
-- The tenant's meters are entered in the app (Production ⚙).
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
  office_share_pct numeric NOT NULL DEFAULT 0 CHECK (office_share_pct >= 0 AND office_share_pct <= 100),   -- not production
  status           text NOT NULL DEFAULT 'active' CHECK (status IN ('active', 'inactive')),
  created_at       timestamptz NOT NULL DEFAULT now(),
  updated_at       timestamptz NOT NULL DEFAULT now()
);
CREATE UNIQUE INDEX uq_power_meters_name ON public.power_meters (branch_id, public.normalize_name(name));
COMMENT ON COLUMN public.power_meters.office_share_pct IS 'Share of the meter''s units used outside production (office…), 0–100 (072).';
CREATE TRIGGER trg_power_meters_updated_at BEFORE UPDATE ON public.power_meters FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();
CREATE TRIGGER trg_power_meters_audit AFTER INSERT OR UPDATE OR DELETE ON public.power_meters FOR EACH ROW EXECUTE FUNCTION public.audit_row_change('power_meter', 'id');
CREATE TRIGGER trg_power_meters_no_delete BEFORE DELETE ON public.power_meters FOR EACH ROW EXECUTE FUNCTION public.prevent_hard_delete('meter');
ALTER TABLE public.power_meters ENABLE ROW LEVEL SECURITY;
CREATE POLICY "power_meters: read own org" ON public.power_meters FOR SELECT USING (organization_id = public.get_my_org_id());
CREATE POLICY "power_meters: branch adds" ON public.power_meters FOR INSERT
  WITH CHECK (organization_id = public.get_my_org_id() AND public.can_keep_production_lists(branch_id));
CREATE POLICY "power_meters: branch changes" ON public.power_meters FOR UPDATE
  USING (organization_id = public.get_my_org_id() AND public.can_keep_production_lists(branch_id))
  WITH CHECK (organization_id = public.get_my_org_id() AND public.can_keep_production_lists(branch_id));

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
                          WHERE m.id = meter_id AND public.can_keep_production_lists(m.branch_id)));
CREATE POLICY "power_meter_machines: branch removes" ON public.power_meter_machines FOR DELETE
  USING (organization_id = public.get_my_org_id()
         AND EXISTS (SELECT 1 FROM public.power_meters m WHERE m.id = meter_id AND public.can_keep_production_lists(m.branch_id)));

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
-- 3. Use between readings
-- ------------------------------------------------------------
CREATE OR REPLACE VIEW public.power_use WITH (security_invoker = true) AS
SELECT r.id AS reading_id, r.organization_id, r.branch_id, r.meter_id, m.name AS meter_name,
       p.read_at AS from_at, r.read_at AS to_at,
       (p.read_at AT TIME ZONE coalesce(o.timezone, 'UTC'))::date AS from_day,
       (r.read_at AT TIME ZONE coalesce(o.timezone, 'UTC'))::date AS day,
       p.reading AS from_reading, r.reading AS to_reading,
       t.loaded AS units_loaded,
       p.reading + t.loaded - r.reading AS units_used,
       pr.price AS price_per_unit,
       round((p.reading + t.loaded - r.reading) * pr.price, 2) AS cost,
       m.office_share_pct,
       round((p.reading + t.loaded - r.reading) * pr.price * (100 - m.office_share_pct) / 100, 2) AS production_cost
FROM public.power_readings r
JOIN public.power_meters m ON m.id = r.meter_id
JOIN public.organizations o ON o.id = r.organization_id
JOIN LATERAL (SELECT read_at, reading FROM public.power_readings x
              WHERE x.meter_id = r.meter_id AND x.status = 'recorded' AND x.read_at < r.read_at
              ORDER BY x.read_at DESC LIMIT 1) p ON true
CROSS JOIN LATERAL (SELECT coalesce(sum(units), 0) AS loaded FROM public.power_tokens k
                    WHERE k.meter_id = r.meter_id AND k.status = 'recorded' AND k.loaded_at > p.read_at AND k.loaded_at <= r.read_at) t
LEFT JOIN LATERAL (SELECT round(k.amount / k.units, 4) AS price FROM public.power_tokens k
                   WHERE k.meter_id = r.meter_id AND k.status = 'recorded' AND k.loaded_at <= r.read_at
                   ORDER BY k.loaded_at DESC LIMIT 1) pr ON true
WHERE r.status = 'recorded';
COMMENT ON VIEW public.power_use IS 'Units and cost of electricity used on a meter between a reading and the one before it (072).';
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
