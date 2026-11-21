WITH b2b_tenants AS (
  SELECT id, name
  FROM tenants
  WHERE lower(coalesce(industry,'')) LIKE '%industrial%supplies%'
     OR lower(coalesce(industry,'')) LIKE '%office%equipment%'
     OR lower(coalesce(industry,'')) LIKE '%industrial%'
     OR lower(coalesce(industry,'')) LIKE '%wholesale%'
     OR lower(coalesce(name,''))     LIKE '%industrial%'
     OR lower(coalesce(name,''))     LIKE '%office%equipment%'
     OR lower(coalesce(slug,''))     LIKE '%industrial%'
     OR lower(coalesce(slug,''))     LIKE '%office-equipment%'
),
scoped_invoices AS (
  SELECT i.*
  FROM invoices i
  JOIN b2b_tenants t ON t.id = i.tenant_id
  WHERE i.issued_at >= DATE '2023-01-01'
    AND i.issued_at <  DATE '2026-01-01'
),
loyalty_users AS (
  SELECT DISTINCT tenant_id, user_id
  FROM loyalty_accounts
),
segmented AS (
  SELECT
    si.*,
    CASE WHEN lu.user_id IS NOT NULL THEN 'loyalty member' ELSE 'non-member' END AS segment
  FROM scoped_invoices si
  LEFT JOIN loyalty_users lu
    ON lu.tenant_id = si.tenant_id AND lu.user_id = si.user_id
),
eur_amounts AS (
  SELECT
    s.*,
    CAST({{divide_decimal(s.total, NULLIF(er.rate, 0))}} AS NUMERIC(18,6)) AS total_eur
  FROM segmented s
  LEFT JOIN exchange_rates er
    ON er.base_code = 'EUR'
   AND er.quote_code = s.currency_code
   AND er.as_of = CAST(s.issued_at AS date)
)
SELECT
  segment,
  COUNT(DISTINCT user_id) AS customer_count,
  COUNT(*) AS invoice_count,
  AVG({{divide_decimal({{seconds_between(issued_at, paid_at)}}, 86400.0)}}) FILTER (WHERE status = 'paid') AS avg_days_to_pay,
  {{divide_decimal(100.0 * COUNT(*) FILTER (WHERE status = 'paid' AND paid_at > due_at), NULLIF(COUNT(*) FILTER (WHERE status = 'paid'), 0))}} AS pct_invoices_paid_late,
  {{divide_decimal(100.0 * COUNT(*) FILTER (
    WHERE status = 'past_due'
       OR (status = 'open' AND due_at < DATE '2025-12-31' AND amount_due > 0)
  ), NULLIF(COUNT(*), 0))}} AS pct_invoices_currently_overdue,
  AVG(total_eur) AS avg_invoice_amount_eur
FROM eur_amounts
GROUP BY segment
ORDER BY CASE WHEN segment = 'loyalty member' THEN 0 ELSE 1 END NULLS LAST, segment NULLS LAST
