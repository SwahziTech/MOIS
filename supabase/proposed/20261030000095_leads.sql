-- ============================================================
-- 095 — CRM: leads and follow-ups (CRM & Cash flow, part 2)
-- ============================================================
-- SwahziTech, 2026-10-30, chose "leads & follow-ups": prospects —
-- contractors, sites, enquiries — before they buy; the next follow-up date
-- and who does it; a lead turned into a customer and a quotation.
--
--   * leads: who, contact, site, where the lead came from, what they want,
--     a rough value, stage (new → contacted → quoted → won / lost with a
--     reason), who follows up, the next follow-up date; the customer and the
--     quotation once made;
--   * lead_follow_ups: each call / visit / WhatsApp / meeting — what was
--     said and the next date (which becomes the lead's); a first follow-up
--     moves a new lead to contacted;
--   * lead_to_customer: the lead becomes a customer (or finds the one it
--     already is), ready for a quotation.
-- Read by those who see sales at the branch; kept by those who sell there.
-- Leads are never deleted — a dead one is marked lost.
-- ============================================================

CREATE TABLE public.leads (
  id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  organization_id uuid NOT NULL REFERENCES public.organizations(id) ON DELETE CASCADE,
  branch_id       uuid NOT NULL REFERENCES public.branches(id) ON DELETE RESTRICT,
  name            text NOT NULL CHECK (btrim(name) <> ''),     -- the person or company
  contact_person  text,
  phone           text,
  email           text,
  site            text,                                         -- where the work is
  source          text CHECK (source IN ('walk_in', 'phone', 'whatsapp', 'referral', 'site_visit', 'social', 'other')),
  interest        text,                                         -- what they want: products, quantities
  estimated_value numeric CHECK (estimated_value >= 0),
  stage           text NOT NULL DEFAULT 'new' CHECK (stage IN ('new', 'contacted', 'quoted', 'won', 'lost')),
  lost_reason     text,
  assigned_to     uuid REFERENCES auth.users(id) ON DELETE SET NULL,   -- who follows up
  next_follow_up  date,
  customer_id     uuid REFERENCES public.customers(id) ON DELETE RESTRICT,
  sale_id         uuid REFERENCES public.sales(id) ON DELETE SET NULL,  -- the quotation made for it
  notes           text,
  created_by      uuid REFERENCES auth.users(id) ON DELETE SET NULL,
  created_at      timestamptz NOT NULL DEFAULT now(),
  updated_at      timestamptz NOT NULL DEFAULT now(),
  CHECK (stage <> 'lost' OR lost_reason IS NOT NULL)
);
CREATE INDEX idx_leads_branch ON public.leads (branch_id, created_at DESC);
CREATE INDEX idx_leads_follow_up ON public.leads (next_follow_up) WHERE stage NOT IN ('won', 'lost');
CREATE TRIGGER trg_leads_updated_at BEFORE UPDATE ON public.leads FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();
CREATE TRIGGER trg_leads_audit AFTER INSERT OR UPDATE OR DELETE ON public.leads FOR EACH ROW EXECUTE FUNCTION public.audit_row_change('lead', 'id');
CREATE TRIGGER trg_leads_no_delete BEFORE DELETE ON public.leads FOR EACH ROW EXECUTE FUNCTION public.prevent_hard_delete('lead');
ALTER TABLE public.leads ENABLE ROW LEVEL SECURITY;
CREATE POLICY "leads: sales read" ON public.leads FOR SELECT
  USING (organization_id = public.get_my_org_id() AND public.has_permission_at('sales.view', branch_id, NULL));
CREATE POLICY "leads: sellers add" ON public.leads FOR INSERT
  WITH CHECK (organization_id = public.get_my_org_id() AND public.has_permission_at('sales.create', branch_id, NULL));
CREATE POLICY "leads: sellers change" ON public.leads FOR UPDATE
  USING (organization_id = public.get_my_org_id() AND public.has_permission_at('sales.create', branch_id, NULL))
  WITH CHECK (organization_id = public.get_my_org_id() AND public.has_permission_at('sales.create', branch_id, NULL));
COMMENT ON TABLE public.leads IS 'Prospects before they buy, with who follows up and when (095).';

CREATE TABLE public.lead_follow_ups (
  id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  organization_id uuid NOT NULL REFERENCES public.organizations(id) ON DELETE CASCADE,
  lead_id         uuid NOT NULL REFERENCES public.leads(id) ON DELETE RESTRICT,
  done_on         date NOT NULL,
  kind            text NOT NULL CHECK (kind IN ('call', 'visit', 'whatsapp', 'meeting', 'other')),
  note            text NOT NULL CHECK (btrim(note) <> ''),   -- what was said or agreed
  next_follow_up  date,                                        -- the next date (NULL = none planned)
  done_by         uuid REFERENCES auth.users(id) ON DELETE SET NULL,
  created_at      timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX idx_lead_follow_ups_lead ON public.lead_follow_ups (lead_id, done_on DESC);
CREATE TRIGGER trg_lead_follow_ups_audit AFTER INSERT OR UPDATE OR DELETE ON public.lead_follow_ups FOR EACH ROW EXECUTE FUNCTION public.audit_row_change('lead_follow_up', 'id');
CREATE TRIGGER trg_lead_follow_ups_no_delete BEFORE DELETE ON public.lead_follow_ups FOR EACH ROW EXECUTE FUNCTION public.prevent_hard_delete('follow-up');
ALTER TABLE public.lead_follow_ups ENABLE ROW LEVEL SECURITY;
CREATE POLICY "lead_follow_ups: sales read" ON public.lead_follow_ups FOR SELECT
  USING (organization_id = public.get_my_org_id()
         AND EXISTS (SELECT 1 FROM public.leads l WHERE l.id = lead_id AND public.has_permission_at('sales.view', l.branch_id, NULL)));
CREATE POLICY "lead_follow_ups: sellers add" ON public.lead_follow_ups FOR INSERT
  WITH CHECK (organization_id = public.get_my_org_id()
              AND EXISTS (SELECT 1 FROM public.leads l WHERE l.id = lead_id AND l.organization_id = lead_follow_ups.organization_id
                          AND public.has_permission_at('sales.create', l.branch_id, NULL)));

-- a follow-up sets the lead's next date; the first one moves a new lead to contacted
CREATE OR REPLACE FUNCTION public.lead_follow_up_done()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  UPDATE public.leads SET next_follow_up = NEW.next_follow_up,
         stage = CASE WHEN stage = 'new' THEN 'contacted' ELSE stage END
  WHERE id = NEW.lead_id;
  RETURN NULL;
END;
$$;
CREATE TRIGGER trg_lead_follow_up_done AFTER INSERT ON public.lead_follow_ups
  FOR EACH ROW EXECUTE FUNCTION public.lead_follow_up_done();

-- the lead becomes a customer (the one already linked, or one with the same name, or a new one) → its id
CREATE OR REPLACE FUNCTION public.lead_to_customer(p_lead uuid)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  l   public.leads;
  cid uuid;
BEGIN
  SELECT * INTO l FROM public.leads WHERE id = p_lead AND organization_id = public.get_my_org_id() FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Lead not found' USING ERRCODE = '23514'; END IF;
  IF NOT public.has_permission_at('sales.create', l.branch_id, NULL) THEN RAISE EXCEPTION 'You can''t make customers at this branch' USING ERRCODE = '42501'; END IF;
  cid := l.customer_id;
  IF cid IS NULL THEN
    SELECT id INTO cid FROM public.customers
    WHERE organization_id = l.organization_id AND public.normalize_name(name) = public.normalize_name(l.name) AND status = 'active'
    ORDER BY created_at LIMIT 1;
  END IF;
  IF cid IS NULL THEN
    INSERT INTO public.customers (organization_id, branch_id, name, phone, email, address, notes, created_by)
    VALUES (l.organization_id, l.branch_id, btrim(l.name), l.phone, l.email, l.site,
            nullif(concat_ws(' · ', CASE WHEN l.contact_person IS NOT NULL THEN 'Contact: ' || l.contact_person END, 'From a lead'), ''), auth.uid())
    RETURNING id INTO cid;
  END IF;
  UPDATE public.leads SET customer_id = cid WHERE id = l.id;
  RETURN cid;
END;
$$;
REVOKE ALL ON FUNCTION public.lead_to_customer(uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.lead_to_customer(uuid) TO authenticated;
