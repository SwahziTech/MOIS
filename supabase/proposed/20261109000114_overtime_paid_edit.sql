-- ============================================================
-- 114 — Overtime: edit the date and amount, mark as paid, delete (2026-11-09, the user)
-- ============================================================
--   * paid_on / paid_by: overtime paid directly (cash, outside a pay sheet). Marked
--     paid, it leaves the draft pay sheet so it is never paid twice; unmarking puts
--     it back. Labour cost still counts it.
--   * A rest day's line can now be deleted, and its date changed (it becomes
--     ordinary overtime on another day).
--   * Approved and paid pay sheets still never change.
-- ============================================================

ALTER TABLE public.staff_overtime
  ADD COLUMN IF NOT EXISTS paid_on date,
  ADD COLUMN IF NOT EXISTS paid_by uuid REFERENCES public.profiles(id);
COMMENT ON COLUMN public.staff_overtime.paid_on IS 'Paid directly on this day — then it stays off the pay sheet (114).';

CREATE OR REPLACE FUNCTION public.fill_pay_sheet_lines(p_sheet uuid)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  ps     public.pay_sheets;
  cfg    public.payroll_settings;
  wd     numeric;
  mstart date;
  half   text;
BEGIN
  SELECT * INTO ps FROM public.pay_sheets WHERE id = p_sheet;
  IF NOT FOUND THEN RETURN; END IF;
  SELECT * INTO cfg FROM public.payroll_settings WHERE organization_id = ps.organization_id;
  cfg.first_half_mode := coalesce(cfg.first_half_mode, 'advance');
  cfg.first_half_pct  := coalesce(cfg.first_half_pct, 50);
  cfg.month_pay_basis := coalesce(cfg.month_pay_basis, 'attendance');
  wd := public.work_days_a_month(ps.organization_id);
  mstart := date_trunc('month', ps.period_start)::date;
  half := CASE WHEN ps.cycle <> 'fortnightly' THEN NULL
               WHEN ps.period_start = mstart AND ps.period_end < (mstart + interval '1 month')::date - 1 THEN 'first'
               WHEN ps.period_start > mstart AND date_trunc('month', ps.period_end)::date = mstart THEN 'second' END;

  INSERT INTO public.pay_sheet_lines (organization_id, sheet_id, staff_id, pay_basis, days, rate, base, amount, part, first_payment, overtime)
  SELECT ps.organization_id, ps.id, st.id, b.basis, d.days, st.pay_rate, x.base, x.base, pt.part, x.first, x.ot
  FROM public.staff st
  CROSS JOIN LATERAL (SELECT coalesce(st.pay_basis, CASE st.kind WHEN 'employed' THEN 'monthly' ELSE 'daily' END) AS basis,
                             coalesce(st.pay_cycle, CASE st.kind WHEN 'employed' THEN 'fortnightly' ELSE 'weekly' END) AS cycle) b
  LEFT JOIN LATERAL (SELECT sum(a.day_fraction) AS days FROM public.staff_attendance a
                     WHERE a.staff_id = st.id AND a.work_date BETWEEN ps.period_start AND ps.period_end AND NOT public.is_rest_day(ps.organization_id, a.work_date)) d ON true
  LEFT JOIN LATERAL (SELECT sum(a.day_fraction) AS days FROM public.staff_attendance a
                     WHERE a.staff_id = st.id AND a.work_date BETWEEN mstart AND ps.period_end AND NOT public.is_rest_day(ps.organization_id, a.work_date)) md ON true
  -- overtime: on the month's last payment for salaried staff paid twice a month (none on the advance), else in the period
  LEFT JOIN LATERAL (SELECT sum(o.amount) AS amount FROM public.staff_overtime o
                     WHERE o.staff_id = st.id AND o.status = 'recorded' AND o.paid_on IS NULL   -- paid directly: not on the sheet (114)
                       AND o.work_date BETWEEN CASE WHEN half = 'second' THEN mstart ELSE ps.period_start END AND ps.period_end) ot ON true
  LEFT JOIN LATERAL (SELECT sum(l.amount) AS paid FROM public.pay_sheet_lines l JOIN public.pay_sheets f ON f.id = l.sheet_id
                     WHERE l.staff_id = st.id AND l.part = 'advance' AND f.id <> ps.id AND f.branch_id = ps.branch_id AND f.cycle = 'fortnightly'
                       AND f.status <> 'void' AND f.period_start = mstart) fp ON true
  CROSS JOIN LATERAL (SELECT CASE WHEN b.basis = 'monthly' AND half = 'first' THEN 'advance'
                                  WHEN b.basis = 'monthly' AND half = 'second' THEN 'balance' END AS part) pt
  CROSS JOIN LATERAL (SELECT
      round(coalesce(CASE
        WHEN b.basis = 'daily' THEN coalesce(d.days, 0) * st.pay_rate
        WHEN pt.part = 'advance' THEN cfg.first_half_pct / 100
             * CASE cfg.first_half_mode WHEN 'advance' THEN st.pay_rate ELSE coalesce(d.days, 0) * st.pay_rate / wd END
        WHEN pt.part = 'balance' OR ps.cycle = 'monthly' THEN
             CASE cfg.month_pay_basis WHEN 'salary' THEN st.pay_rate
                  ELSE coalesce(CASE WHEN pt.part = 'balance' THEN md.days ELSE d.days END, 0) * st.pay_rate / wd END
        ELSE coalesce(d.days, 0) * st.pay_rate / wd END, 0), 2) AS base,
      CASE WHEN pt.part = 'balance' THEN coalesce(fp.paid, 0) ELSE 0 END AS first,
      CASE WHEN pt.part = 'advance' THEN 0 ELSE coalesce(ot.amount, 0) END AS ot) x
  WHERE st.branch_id = ps.branch_id
    AND b.cycle = ps.cycle
    AND (st.started_on IS NULL OR st.started_on <= ps.period_end)
    AND (st.status = 'active' OR st.left_on >= ps.period_start OR d.days > 0)
    AND (coalesce(d.days, 0) > 0
         OR (coalesce(ot.amount, 0) > 0 AND coalesce(pt.part, '') <> 'advance')
         OR (pt.part = 'advance' AND cfg.first_half_mode = 'advance')
         OR (b.basis = 'monthly' AND (pt.part = 'balance' OR ps.cycle = 'monthly')
             AND (cfg.month_pay_basis = 'salary' OR coalesce(md.days, 0) > 0 OR coalesce(fp.paid, 0) > 0)));
  PERFORM public.compute_pay_sheet(p_sheet);
END;
$$;


-- p: { id?, staff_id, work_date, amount, note?, void?, paid?, paid_on? }
CREATE OR REPLACE FUNCTION public.save_overtime(p jsonb)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  old public.staff_overtime;
  st  public.staff;
  dt  date := nullif(p->>'work_date', '')::date;
  amt numeric := nullif(p->>'amount', '')::numeric;
  new_id uuid;
  on_sheet boolean;
BEGIN
  IF nullif(p->>'id', '') IS NOT NULL THEN
    SELECT * INTO old FROM public.staff_overtime WHERE id = (p->>'id')::uuid AND organization_id = public.get_my_org_id() AND status = 'recorded' FOR UPDATE;
    IF NOT FOUND THEN RAISE EXCEPTION 'Overtime not found' USING ERRCODE = '23514'; END IF;
    p := p || jsonb_build_object('staff_id', old.staff_id);
    dt := coalesce(dt, old.work_date);
  END IF;
  SELECT * INTO st FROM public.staff WHERE id = (p->>'staff_id')::uuid AND organization_id = public.get_my_org_id();
  IF NOT FOUND THEN RAISE EXCEPTION 'Staff member not found' USING ERRCODE = '23514'; END IF;
  IF NOT public.has_permission_at('payroll.record', st.branch_id, NULL) THEN RAISE EXCEPTION 'You can''t enter overtime at this branch' USING ERRCODE = '42501'; END IF;
  IF dt IS NULL THEN RAISE EXCEPTION 'Choose the day' USING ERRCODE = '23514'; END IF;
  IF dt > public.org_today(st.organization_id) THEN RAISE EXCEPTION 'The date can''t be in the future' USING ERRCODE = '23514'; END IF;
  -- the day (old and new) must not be on an approved or paid pay sheet
  SELECT EXISTS (SELECT 1 FROM public.pay_sheets s
             WHERE s.branch_id = st.branch_id AND s.status IN ('approved', 'paid')
               AND (dt BETWEEN s.period_start AND s.period_end OR (old.id IS NOT NULL AND old.work_date BETWEEN s.period_start AND s.period_end))
               AND (s.cycle = public.cycle_of_staff(st)
                    OR EXISTS (SELECT 1 FROM public.pay_sheet_lines l WHERE l.sheet_id = s.id AND l.staff_id = st.id))) INTO on_sheet;
  -- paid directly / not paid (114)
  IF p ? 'paid' THEN
    IF old.id IS NULL THEN RAISE EXCEPTION 'Overtime not found' USING ERRCODE = '23514'; END IF;
    IF on_sheet THEN RAISE EXCEPTION 'That day''s pay sheet is approved — it already pays this overtime' USING ERRCODE = '23514'; END IF;
    IF (p->>'paid')::boolean THEN
      UPDATE public.staff_overtime SET paid_on = coalesce(nullif(p->>'paid_on', '')::date, public.org_today(st.organization_id)), paid_by = auth.uid() WHERE id = old.id;
    ELSE
      UPDATE public.staff_overtime SET paid_on = NULL, paid_by = NULL WHERE id = old.id;
    END IF;
    RETURN old.id;
  END IF;
  IF on_sheet THEN RAISE EXCEPTION 'That day''s pay sheet is approved — overtime can''t change' USING ERRCODE = '23514'; END IF;
  IF coalesce((p->>'void')::boolean, false) THEN
    IF old.id IS NULL THEN RAISE EXCEPTION 'Overtime not found' USING ERRCODE = '23514'; END IF;
    UPDATE public.staff_overtime SET status = 'void' WHERE id = old.id;   -- a rest day's line too (114)
    RETURN old.id;
  END IF;
  IF amt IS NULL OR amt < 0 THEN RAISE EXCEPTION 'Enter the amount' USING ERRCODE = '23514'; END IF;
  IF old.id IS NOT NULL THEN
    -- a rest day moved to another day becomes ordinary overtime (114)
    UPDATE public.staff_overtime SET amount = round(amt, 2), work_date = dt, note = nullif(btrim(p->>'note'), ''), edited = true,
           kind = CASE WHEN old.kind = 'rest_day' AND dt <> old.work_date THEN 'other' ELSE old.kind END
     WHERE id = old.id;
    RETURN old.id;
  END IF;
  IF public.is_rest_day(st.organization_id, dt) THEN RAISE EXCEPTION 'Tick the person on attendance for this day; the overtime appears here to adjust' USING ERRCODE = '23514'; END IF;
  INSERT INTO public.staff_overtime (organization_id, branch_id, staff_id, work_date, amount, note, created_by)
  VALUES (st.organization_id, st.branch_id, st.id, dt, round(amt, 2), nullif(btrim(p->>'note'), ''), auth.uid())
  RETURNING id INTO new_id;
  RETURN new_id;
END;
$$;
REVOKE ALL ON FUNCTION public.save_overtime(jsonb) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.save_overtime(jsonb) TO authenticated;
