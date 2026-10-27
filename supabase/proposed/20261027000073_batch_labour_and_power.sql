-- ============================================================
-- 073 — Labour and electricity in a batch's cost (1e, full production cost)
--
-- SwahziTech, 2026-10-27:
--   * labour (a placeholder until the Staff/HR phase): the casual labourers
--     who worked that day × the branch's casual day rate, shared over the
--     day's batches by cement bags — each wage counted once a day, however
--     many batches a person worked on;
--   * electricity (072): each meter's production cost for the day (a
--     stretch between readings spread evenly over its days) shared over that
--     day's batches on the meter's machines, by cement bags.
-- A batch output's cost per unit becomes materials + its share of labour and
-- electricity (by cement taken, as materials are shared — 055).
-- The day rate is a branch setting entered in the app.
-- ============================================================

ALTER TABLE public.branches ADD COLUMN casual_day_rate numeric CHECK (casual_day_rate >= 0);
COMMENT ON COLUMN public.branches.casual_day_rate IS 'What a casual labourer is paid a day — labour cost until the Staff/HR phase (073).';

ALTER TABLE public.production_batches
  ADD COLUMN labour_cost numeric,          -- its share of the day's casual wages (NULL = the day's labourers not entered)
  ADD COLUMN power_cost  numeric;          -- its share of the day's electricity on its machine's meter
COMMENT ON COLUMN public.production_batches.labour_cost IS 'Share of the day''s casual wages, by cement bags (073).';
COMMENT ON COLUMN public.production_batches.power_cost IS 'Share of the day''s production electricity on its machine''s meter, by cement bags (073).';

-- ------------------------------------------------------------
-- 1. The casual labourers who worked on a day at a branch
-- ------------------------------------------------------------
CREATE TABLE public.production_day_labour (
  organization_id  uuid NOT NULL REFERENCES public.organizations(id) ON DELETE CASCADE,
  branch_id        uuid NOT NULL REFERENCES public.branches(id) ON DELETE RESTRICT,
  day              date NOT NULL,
  casual_labourers int  NOT NULL CHECK (casual_labourers >= 0),
  day_rate         numeric NOT NULL CHECK (day_rate >= 0),     -- the branch's rate when entered
  recorded_by      uuid REFERENCES auth.users(id) ON DELETE SET NULL,
  updated_at       timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (branch_id, day)
);
CREATE TRIGGER trg_production_day_labour_audit AFTER INSERT OR UPDATE OR DELETE ON public.production_day_labour
  FOR EACH ROW EXECUTE FUNCTION public.audit_row_change('production_day_labour', 'branch_id,day');
ALTER TABLE public.production_day_labour ENABLE ROW LEVEL SECURITY;
CREATE POLICY "production_day_labour: read own org" ON public.production_day_labour FOR SELECT USING (organization_id = public.get_my_org_id());

-- ------------------------------------------------------------
-- 2. Share a day's labour and electricity over its batches
-- ------------------------------------------------------------
CREATE FUNCTION public.production_overheads_day(p_branch uuid, p_day date)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  lab  public.production_day_labour;
  bags numeric;
  m    record;
BEGIN
  SELECT sum(cement_bags) INTO bags FROM public.production_batches WHERE branch_id = p_branch AND batch_date = p_day AND status <> 'void';
  IF coalesce(bags, 0) = 0 THEN RETURN; END IF;

  -- labour: the day's wages by cement bags
  SELECT * INTO lab FROM public.production_day_labour WHERE branch_id = p_branch AND day = p_day;
  UPDATE public.production_batches b
     SET labour_cost = CASE WHEN lab.day IS NULL THEN NULL ELSE round(lab.casual_labourers * lab.day_rate * b.cement_bags / bags, 2) END,
         power_cost = 0
   WHERE b.branch_id = p_branch AND b.batch_date = p_day AND b.status <> 'void';

  -- electricity: each meter's production cost that day over the batches on its machines
  FOR m IN
    SELECT u.meter_id, sum(u.production_cost / u.days) AS cost
      FROM public.power_use u
     WHERE u.branch_id = p_branch AND u.from_day < p_day AND u.day >= p_day AND u.production_cost IS NOT NULL
     GROUP BY u.meter_id
  LOOP
    UPDATE public.production_batches b
       SET power_cost = round(m.cost * b.cement_bags / s.bags, 2)
      FROM (SELECT sum(x.cement_bags) AS bags FROM public.production_batches x
             JOIN public.power_meter_machines pm ON pm.machine_id = x.machine_id AND pm.meter_id = m.meter_id
            WHERE x.branch_id = p_branch AND x.batch_date = p_day AND x.status <> 'void') s
     WHERE b.branch_id = p_branch AND b.batch_date = p_day AND b.status <> 'void' AND s.bags > 0
       AND b.machine_id IN (SELECT machine_id FROM public.power_meter_machines WHERE meter_id = m.meter_id);
  END LOOP;
END;
$$;
REVOKE ALL ON FUNCTION public.production_overheads_day(uuid, date) FROM PUBLIC, anon, authenticated;

CREATE FUNCTION public.production_overheads_range(p_branch uuid, p_from date, p_to date)
RETURNS void
LANGUAGE sql
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT public.production_overheads_day(p_branch, d)
    FROM (SELECT DISTINCT batch_date AS d FROM public.production_batches
           WHERE branch_id = p_branch AND batch_date BETWEEN p_from AND p_to) x;
$$;
REVOKE ALL ON FUNCTION public.production_overheads_range(uuid, date, date) FROM PUBLIC, anon, authenticated;

-- a meter's whole stretch of readings (its readings, tokens or set-up changed)
CREATE FUNCTION public.production_overheads_meter(p_meter uuid)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  br uuid;
  tz text;
  lo date;
  hi date;
BEGIN
  SELECT m.branch_id, coalesce(o.timezone, 'UTC') INTO br, tz FROM public.power_meters m JOIN public.organizations o ON o.id = m.organization_id WHERE m.id = p_meter;
  SELECT min((read_at AT TIME ZONE tz)::date), max((read_at AT TIME ZONE tz)::date) INTO lo, hi FROM public.power_readings WHERE meter_id = p_meter;
  IF lo IS NOT NULL THEN PERFORM public.production_overheads_range(br, lo, hi); END IF;
END;
$$;
REVOKE ALL ON FUNCTION public.production_overheads_meter(uuid) FROM PUBLIC, anon, authenticated;

-- ------------------------------------------------------------
-- 3. Kept up to date
-- ------------------------------------------------------------
CREATE FUNCTION public.trg_batch_overheads()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
BEGIN
  PERFORM public.production_overheads_day(NEW.branch_id, NEW.batch_date);
  IF TG_OP = 'UPDATE' AND OLD.batch_date IS DISTINCT FROM NEW.batch_date THEN
    PERFORM public.production_overheads_day(OLD.branch_id, OLD.batch_date);
  END IF;
  RETURN NULL;
END;
$$;
CREATE TRIGGER trg_production_batches_overheads
  AFTER INSERT OR UPDATE OF status, cement_bags, machine_id, batch_date ON public.production_batches
  FOR EACH ROW EXECUTE FUNCTION public.trg_batch_overheads();

CREATE FUNCTION public.trg_meter_overheads()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
BEGIN
  -- a meter's own row carries id; readings, tokens and links carry meter_id
  PERFORM public.production_overheads_meter((to_jsonb(coalesce(NEW, OLD)) ->> CASE WHEN TG_TABLE_NAME = 'power_meters' THEN 'id' ELSE 'meter_id' END)::uuid);
  RETURN NULL;
END;
$$;
CREATE TRIGGER trg_power_readings_overheads AFTER INSERT OR UPDATE ON public.power_readings
  FOR EACH ROW EXECUTE FUNCTION public.trg_meter_overheads();
CREATE TRIGGER trg_power_tokens_overheads AFTER INSERT OR UPDATE ON public.power_tokens
  FOR EACH ROW EXECUTE FUNCTION public.trg_meter_overheads();
CREATE TRIGGER trg_power_meters_overheads AFTER UPDATE OF split_mode, baseline_units_per_day ON public.power_meters
  FOR EACH ROW EXECUTE FUNCTION public.trg_meter_overheads();
CREATE TRIGGER trg_power_meter_machines_overheads AFTER INSERT OR DELETE ON public.power_meter_machines
  FOR EACH ROW EXECUTE FUNCTION public.trg_meter_overheads();

-- ------------------------------------------------------------
-- 4. Enter the day's casual labourers; the branch's day rate
-- ------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.set_day_labour(p_branch uuid, p_day date, p_count int)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  rate numeric;
BEGIN
  IF NOT public.has_permission_at('production.create', p_branch, NULL) THEN RAISE EXCEPTION 'You can''t record production at this branch' USING ERRCODE = '42501'; END IF;
  SELECT casual_day_rate INTO rate FROM public.branches WHERE id = p_branch AND organization_id = public.get_my_org_id();
  IF NOT FOUND THEN RAISE EXCEPTION 'Branch not found' USING ERRCODE = '23514'; END IF;
  IF p_day IS NULL OR p_day > public.org_today(public.get_my_org_id()) THEN RAISE EXCEPTION 'Choose the day' USING ERRCODE = '23514'; END IF;
  IF p_count IS NULL THEN
    DELETE FROM public.production_day_labour WHERE branch_id = p_branch AND day = p_day;
  ELSE
    IF p_count < 0 THEN RAISE EXCEPTION 'Labourers can''t be negative' USING ERRCODE = '23514'; END IF;
    IF rate IS NULL THEN RAISE EXCEPTION 'Set the casual day rate first (Production ⚙)' USING ERRCODE = '23514'; END IF;
    INSERT INTO public.production_day_labour (organization_id, branch_id, day, casual_labourers, day_rate, recorded_by)
    VALUES (public.get_my_org_id(), p_branch, p_day, p_count, rate, auth.uid())
    ON CONFLICT (branch_id, day) DO UPDATE SET casual_labourers = EXCLUDED.casual_labourers, day_rate = EXCLUDED.day_rate,
                                               recorded_by = EXCLUDED.recorded_by, updated_at = now();
  END IF;
  PERFORM public.production_overheads_day(p_branch, p_day);
END;
$$;

CREATE OR REPLACE FUNCTION public.set_branch_casual_day_rate(p_branch uuid, p_rate numeric)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  IF NOT public.can_keep_production_lists(p_branch) THEN RAISE EXCEPTION 'You can''t change this branch''s settings' USING ERRCODE = '42501'; END IF;
  IF p_rate IS NOT NULL AND p_rate < 0 THEN RAISE EXCEPTION 'The rate can''t be negative' USING ERRCODE = '23514'; END IF;
  UPDATE public.branches SET casual_day_rate = p_rate WHERE id = p_branch AND organization_id = public.get_my_org_id();
  IF NOT FOUND THEN RAISE EXCEPTION 'Branch not found' USING ERRCODE = '23514'; END IF;
  -- days already entered keep the rate they were entered with
END;
$$;

REVOKE ALL ON FUNCTION public.set_day_labour(uuid, date, int), public.set_branch_casual_day_rate(uuid, numeric) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.set_day_labour(uuid, date, int), public.set_branch_casual_day_rate(uuid, numeric) TO authenticated;

-- ------------------------------------------------------------
-- 5. A batch output's cost per stock unit: materials + its share of labour and electricity
--    (replaces 058's; stock value, costing and sales margins all read it)
-- ------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.output_cost_per_unit(p_output public.production_batch_outputs)
RETURNS numeric LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
  SELECT CASE WHEN p_output.material_cost IS NOT NULL AND p_output.pieces_cast > 0
              THEN (p_output.material_cost
                    + coalesce((SELECT (coalesce(b.labour_cost, 0) + coalesce(b.power_cost, 0)) * coalesce(p_output.cement_share, 0)
                                  FROM public.production_batches b WHERE b.id = p_output.batch_id), 0))
                   / nullif(public.production_stock_qty(p_output.product_id, p_output.pieces_cast), 0) END
$$;

-- batches already recorded: electricity and labour start at 0 / not entered
UPDATE public.production_batches SET power_cost = 0 WHERE status <> 'void';
