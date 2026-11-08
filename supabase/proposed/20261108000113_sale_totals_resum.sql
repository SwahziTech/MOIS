-- 113 (2026-11-08): 112 rounded a sale line to whole shillings, but the sale's own
-- totals were re-summed in the same statement and still saw the old line (a WITH
-- ... UPDATE reads the snapshot from before). Re-sum every sale whose totals
-- differ from its lines.
UPDATE public.sales s
   SET subtotal = x.amount, vat = x.vat, total = x.total
  FROM (SELECT sale_id, sum(amount) AS amount, sum(vat) AS vat, sum(total) AS total
          FROM public.sale_lines GROUP BY sale_id) x
 WHERE x.sale_id = s.id
   AND (s.total IS DISTINCT FROM x.total OR s.subtotal IS DISTINCT FROM x.amount OR s.vat IS DISTINCT FROM x.vat);
