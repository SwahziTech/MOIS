-- ============================================================
-- 066 — Company details on documents (1e)
--
-- SwahziTech, 2026-10-26: printable quotation, proforma/order, invoice,
-- payment receipt and delivery note carry the company's details. The
-- organization had a legal name and an (empty) logo only.
--   * tin, vrn, address, phone, email — set by org admins (org.manage);
--   * bank_details — how customers pay (bank accounts, mobile money numbers),
--     printed on quotations and invoices;
--   * document_footer — terms printed at the foot of every document;
--   * the legal name and logo stay Technical-admin only (034); the logo is
--     kept as a small image in logo_url (a data URL, at most ~300 KB).
-- ============================================================

ALTER TABLE public.organizations
  ADD COLUMN tin             text,
  ADD COLUMN vrn             text,
  ADD COLUMN address         text,
  ADD COLUMN phone           text,
  ADD COLUMN email           text,
  ADD COLUMN bank_details    text,
  ADD COLUMN document_footer text,
  ADD CONSTRAINT organizations_logo_size CHECK (logo_url IS NULL OR length(logo_url) <= 400000);
COMMENT ON COLUMN public.organizations.bank_details IS 'How customers pay — printed on quotations and invoices (066).';
COMMENT ON COLUMN public.organizations.document_footer IS 'Terms printed at the foot of every document (066).';
