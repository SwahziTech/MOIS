-- ============================================================
-- 053 — Material cost is the full amount paid, VAT included (1c)
--
-- SwahziTech, 2026-10-24: "use the exact full amount paid, whether VAT is
-- excluded or included; just state it and the amounts for procurement".
-- Replaces 035's rule (VAT taken out of cost when shown separately):
--   prices entered WITH VAT    → the line amount as entered
--   prices entered WITHOUT VAT → the line amount plus its share of the VAT
-- plus its share of transport, as before. The VAT itself is still recorded
-- on each purchase (vat_amount) and now also per line (vat_share), for
-- procurement reports. Stock value (052) and the 035 average both read this
-- view, so every material cost follows the new rule at once.
-- ============================================================

CREATE OR REPLACE VIEW public.purchase_line_costs
WITH (security_invoker = true) AS
SELECT l.id AS purchase_line_id, l.purchase_id, l.transaction_id, p.organization_id, p.branch_id, p.supplier_id, p.purchase_date,
       t.material_id, t.warehouse_id, t.seq, t.quantity AS stock_quantity, t.stock_unit_id, t.entered_quantity, t.entered_unit_id,
       l.unit_price, l.line_amount,
       l.line_amount * CASE WHEN NOT p.prices_include_vat AND coalesce(p.vat_amount, 0) > 0 AND s.subtotal > 0
                            THEN (s.subtotal + p.vat_amount) / s.subtotal ELSE 1 END
       + CASE WHEN s.subtotal > 0 THEN p.transport_charge * l.line_amount / s.subtotal
              ELSE p.transport_charge / s.lines END                         AS landed_cost,
       ( l.line_amount * CASE WHEN NOT p.prices_include_vat AND coalesce(p.vat_amount, 0) > 0 AND s.subtotal > 0
                              THEN (s.subtotal + p.vat_amount) / s.subtotal ELSE 1 END
         + CASE WHEN s.subtotal > 0 THEN p.transport_charge * l.line_amount / s.subtotal
                ELSE p.transport_charge / s.lines END ) / nullif(t.quantity, 0) AS cost_per_stock_unit,
       CASE WHEN coalesce(p.vat_amount, 0) > 0 AND s.subtotal > 0 THEN p.vat_amount * l.line_amount / s.subtotal ELSE 0 END AS vat_share
FROM public.purchase_lines l
JOIN public.purchases p ON p.id = l.purchase_id AND p.status = 'recorded'
JOIN public.inventory_transactions t ON t.id = l.transaction_id
JOIN LATERAL (SELECT sum(line_amount) AS subtotal, count(*) AS lines FROM public.purchase_lines WHERE purchase_id = p.id) s ON true;
COMMENT ON VIEW public.purchase_line_costs IS 'Each purchase line''s cost: the full amount paid incl. VAT plus its share of transport (053); vat_share = its VAT, for procurement.';
