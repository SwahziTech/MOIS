-- ============================================================
-- 096 — Deliveries: driver, on the way → delivered, proof of delivery
-- ============================================================
-- SwahziTech, 2026-10-30, chose "Deliveries & documents" (PRD 4.12, 4.14):
-- a delivery leaves with a driver and vehicle and is "on the way" until
-- someone confirms it arrived — who received it, when, a note (proof of
-- delivery). A collection is delivered on the spot. The stock already left
-- when the delivery was recorded (065); this only tracks the trip.
-- Deliveries recorded before today count as delivered.
-- ============================================================

ALTER TABLE public.sale_deliveries
  ADD COLUMN driver          text,
  ADD COLUMN status          text NOT NULL DEFAULT 'delivered' CHECK (status IN ('on_the_way', 'delivered')),
  ADD COLUMN dispatched_at   timestamptz,
  ADD COLUMN delivered_at    timestamptz,
  ADD COLUMN pod_received_by text,          -- who took the goods at the site
  ADD COLUMN pod_note        text,          -- shortages, damage, where left
  ADD COLUMN confirmed_by    uuid REFERENCES auth.users(id) ON DELETE SET NULL;
COMMENT ON COLUMN public.sale_deliveries.status IS 'on_the_way until confirmed delivered (proof of delivery); a collection is delivered on the spot (096).';

-- deliveries already recorded: delivered when recorded
UPDATE public.sale_deliveries SET status = 'delivered', dispatched_at = created_at, delivered_at = created_at, pod_received_by = received_by
WHERE delivered_at IS NULL;

-- a new delivery is on the way; a collection is delivered at once
CREATE OR REPLACE FUNCTION public.delivery_starts()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = public
AS $$
BEGIN
  NEW.dispatched_at := coalesce(NEW.dispatched_at, now());
  IF NEW.kind = 'delivery' THEN
    NEW.status := 'on_the_way';
  ELSE
    NEW.status := 'delivered';
    NEW.delivered_at := coalesce(NEW.delivered_at, now());
    NEW.pod_received_by := coalesce(NEW.pod_received_by, NEW.received_by);
  END IF;
  RETURN NEW;
END;
$$;
CREATE TRIGGER trg_delivery_starts BEFORE INSERT ON public.sale_deliveries
  FOR EACH ROW EXECUTE FUNCTION public.delivery_starts();

-- the trip's details: driver and vehicle (set when it leaves, changeable until delivered)
-- p: { driver?, vehicle? }
CREATE OR REPLACE FUNCTION public.set_delivery_trip(p_delivery uuid, p jsonb)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  d  public.sale_deliveries;
  br uuid;
BEGIN
  SELECT * INTO d FROM public.sale_deliveries WHERE id = p_delivery AND organization_id = public.get_my_org_id() FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Delivery not found' USING ERRCODE = '23514'; END IF;
  SELECT branch_id INTO br FROM public.sales WHERE id = d.sale_id;
  IF NOT public.has_permission_at('sales.create', br, NULL) THEN RAISE EXCEPTION 'You can''t change deliveries at this branch' USING ERRCODE = '42501'; END IF;
  IF d.status = 'delivered' AND d.kind = 'delivery' THEN RAISE EXCEPTION 'It is already delivered' USING ERRCODE = '23514'; END IF;
  UPDATE public.sale_deliveries SET
    driver  = CASE WHEN p ? 'driver'  THEN nullif(btrim(p->>'driver'), '')  ELSE driver END,
    vehicle = CASE WHEN p ? 'vehicle' THEN nullif(btrim(p->>'vehicle'), '') ELSE vehicle END
  WHERE id = d.id;
END;
$$;

-- proof of delivery: it arrived — who received it, when, a note
-- p: { received_by, delivered_at?, note? }
CREATE OR REPLACE FUNCTION public.confirm_delivery(p_delivery uuid, p jsonb)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  d  public.sale_deliveries;
  br uuid;
  at timestamptz := coalesce(nullif(p->>'delivered_at', '')::timestamptz, now());
BEGIN
  SELECT * INTO d FROM public.sale_deliveries WHERE id = p_delivery AND organization_id = public.get_my_org_id() FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Delivery not found' USING ERRCODE = '23514'; END IF;
  SELECT branch_id INTO br FROM public.sales WHERE id = d.sale_id;
  IF NOT public.has_permission_at('sales.create', br, NULL) THEN RAISE EXCEPTION 'You can''t confirm deliveries at this branch' USING ERRCODE = '42501'; END IF;
  IF d.status = 'delivered' THEN RAISE EXCEPTION 'It is already delivered' USING ERRCODE = '23514'; END IF;
  IF nullif(btrim(p->>'received_by'), '') IS NULL THEN RAISE EXCEPTION 'Enter who received the goods' USING ERRCODE = '23514'; END IF;
  IF at > now() + interval '5 minutes' THEN RAISE EXCEPTION 'The time can''t be in the future' USING ERRCODE = '23514'; END IF;
  IF at < d.dispatched_at THEN RAISE EXCEPTION 'It can''t arrive before it left' USING ERRCODE = '23514'; END IF;
  UPDATE public.sale_deliveries SET status = 'delivered', delivered_at = at, pod_received_by = btrim(p->>'received_by'),
         pod_note = nullif(btrim(p->>'note'), ''), confirmed_by = auth.uid()
  WHERE id = d.id;
END;
$$;
REVOKE ALL ON FUNCTION public.set_delivery_trip(uuid, jsonb), public.confirm_delivery(uuid, jsonb) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.set_delivery_trip(uuid, jsonb), public.confirm_delivery(uuid, jsonb) TO authenticated;
