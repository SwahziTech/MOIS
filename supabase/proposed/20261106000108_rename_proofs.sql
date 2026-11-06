-- ============================================================
-- 108 — Proofs already posted get names from their transaction
-- ============================================================
-- SwahziTech, 2026-11-06, the user: proofs are named after the transaction
-- they prove, for easy finding (the app names new ones the same way):
--   Sale-12_<customer>_<amount>_<date>.<ext>
--   Paid-Supplier|Expense|WeeklyCash|Salaries|Other_<who>_<amount>_<date>.<ext>
-- Only the shown name (file_name) changes; the stored file and its records stay.
-- ============================================================

CREATE OR REPLACE FUNCTION pg_temp.proof_part(s text)
RETURNS text LANGUAGE sql IMMUTABLE AS $$
  SELECT left(btrim(regexp_replace(coalesce(s, ''), '[^A-Za-z0-9_.-]+', '-', 'g'), '-'), 40)
$$;
CREATE OR REPLACE FUNCTION pg_temp.proof_ext(p text)
RETURNS text LANGUAGE sql IMMUTABLE AS $$
  SELECT CASE WHEN p ~ '\.[A-Za-z0-9]{2,5}$' THEN lower(substring(p FROM '\.([A-Za-z0-9]{2,5})$')) ELSE 'jpg' END
$$;

-- sale payments
UPDATE public.sale_payment_proofs pr
   SET file_name = 'Sale-' || s.sale_no
       || '_' || pg_temp.proof_part(coalesce(c.name, s.walk_in_name, 'Walk-in'))
       || '_' || round(pay.amount)::bigint
       || '_' || pay.paid_on
       || '.' || pg_temp.proof_ext(pr.file_path)
  FROM public.sale_payments pay
  JOIN public.sales s ON s.id = pay.sale_id
  LEFT JOIN public.customers c ON c.id = s.customer_id
 WHERE pay.id = pr.payment_id AND pr.file_path IS NOT NULL;

-- what directors paid
UPDATE public.director_payments d
   SET file_name = 'Paid-' || CASE d.kind WHEN 'supplier' THEN 'Supplier' WHEN 'expense' THEN 'Expense' WHEN 'weekly_cash' THEN 'WeeklyCash'
                                         WHEN 'salaries' THEN 'Salaries' ELSE 'Other' END
       || '_' || pg_temp.proof_part(coalesce(
            CASE d.kind WHEN 'supplier' THEN (SELECT sp.name FROM public.purchases pu JOIN public.suppliers sp ON sp.id = pu.supplier_id WHERE pu.id = d.ref_id)
                        WHEN 'expense' THEN (SELECT e.description FROM public.expenses e WHERE e.id = d.ref_id) END,
            d.description, (SELECT b.name FROM public.branches b WHERE b.id = d.branch_id)))
       || '_' || round(d.amount)::bigint
       || '_' || d.paid_on
       || '.' || pg_temp.proof_ext(d.file_path)
 WHERE d.file_path IS NOT NULL;
