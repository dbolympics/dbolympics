WITH target_tenants AS (
  SELECT t0.id AS tenant_id, t0.name AS tenant_name, t0.default_currency_code AS currency_code
  FROM tenants t0
  WHERE t0.name IN (
    'Ballycorran Industrial Supply', 'Kontor24 Burobedarf', 'OfficeHub Nordic',
    'Midland Safety Wear', 'Castell Fasteners', 'Hanse Industriebedarf',
    'Polder Packaging', 'Deskline Supplies', 'Papeterie Grossiste'
  )
  AND EXISTS (SELECT 1 FROM deals d0 WHERE d0.tenant_id = t0.id)
),
revenue_tenant AS (
  SELECT p0.tenant_id AS tenant_id,
    SUM(CASE WHEN p0.currency_code = 'EUR' THEN CAST(p0.amount AS NUMERIC(18,6))
             ELSE CAST({{divide_decimal(p0.amount, er0.rate)}} AS NUMERIC(18,6)) END) AS total_2025_revenue_eur
  FROM payments p0
  LEFT JOIN exchange_rates er0
    ON er0.base_code = 'EUR'
   AND er0.quote_code = p0.currency_code
   AND er0.as_of = CAST(p0.captured_at AS date)
  WHERE p0.status IN ('captured', 'refunded', 'partially_refunded')
    AND p0.captured_at >= DATE '2025-01-01'
    AND p0.captured_at < DATE '2026-01-01'
  GROUP BY p0.tenant_id
),
revenue_all AS (
  SELECT SUM(CASE WHEN p1.currency_code = 'EUR' THEN CAST(p1.amount AS NUMERIC(18,6))
                  ELSE CAST({{divide_decimal(p1.amount, er1.rate)}} AS NUMERIC(18,6)) END) AS total_revenue_eur_all
  FROM payments p1
  LEFT JOIN exchange_rates er1
    ON er1.base_code = 'EUR'
   AND er1.quote_code = p1.currency_code
   AND er1.as_of = CAST(p1.captured_at AS date)
  WHERE p1.status IN ('captured', 'refunded', 'partially_refunded')
    AND p1.captured_at >= DATE '2025-01-01'
    AND p1.captured_at < DATE '2026-01-01'
),
open_invoices_tenant AS (
  SELECT i0.tenant_id AS tenant_id,
    SUM(CASE WHEN i0.currency_code = 'EUR' THEN CAST(i0.amount_due AS NUMERIC(18,6))
             ELSE CAST({{divide_decimal(i0.amount_due, er2.rate)}} AS NUMERIC(18,6)) END) AS open_amount_due_eur,
    SUM(CASE WHEN i0.due_at < TIMESTAMP '2025-12-31 00:00:00'
             THEN (CASE WHEN i0.currency_code = 'EUR' THEN CAST(i0.amount_due AS NUMERIC(18,6))
                        ELSE CAST({{divide_decimal(i0.amount_due, er2.rate)}} AS NUMERIC(18,6)) END)
             ELSE 0 END) AS overdue_amount_due_eur
  FROM invoices i0
  LEFT JOIN exchange_rates er2
    ON er2.base_code = 'EUR'
   AND er2.quote_code = i0.currency_code
   AND er2.as_of = DATE '2025-12-31'
  WHERE i0.status IN ('open', 'past_due')
    AND i0.amount_due > 0
  GROUP BY i0.tenant_id
)
SELECT
  tt0.tenant_name AS tenant_name,
  tt0.currency_code AS currency_code,
  COALESCE(rt0.total_2025_revenue_eur, 0) AS total_2025_revenue_eur,
  {{divide_decimal(COALESCE(rt0.total_2025_revenue_eur, 0), NULLIF(ra0.total_revenue_eur_all, 0))}} * 100 AS pct_of_total_2025_revenue,
  COALESCE(oi0.open_amount_due_eur, 0) AS open_amount_due_eur,
  CASE WHEN COALESCE(oi0.open_amount_due_eur, 0) = 0 THEN NULL
       ELSE {{divide_decimal(oi0.overdue_amount_due_eur, oi0.open_amount_due_eur)}} * 100 END AS pct_amount_due_overdue
FROM target_tenants tt0
LEFT JOIN revenue_tenant rt0 ON rt0.tenant_id = tt0.tenant_id
CROSS JOIN revenue_all ra0
LEFT JOIN open_invoices_tenant oi0 ON oi0.tenant_id = tt0.tenant_id
ORDER BY total_2025_revenue_eur DESC NULLS FIRST, tt0.tenant_name NULLS LAST, tt0.tenant_id NULLS LAST
