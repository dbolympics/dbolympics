WITH gross_by_tenant AS (
  SELECT
    p.tenant_id AS tenant_id,
    SUM({{divide_decimal(p.gross_amount, CASE WHEN p.currency_code = 'EUR' THEN 1 ELSE er.rate END)}}) AS gross_volume_eur
  FROM payouts p
  LEFT JOIN exchange_rates er
    ON er.base_code = 'EUR'
   AND er.quote_code = p.currency_code
   AND er.as_of = CAST(p.paid_at AS date)
  WHERE p.paid_at >= DATE '2025-01-01'
    AND p.paid_at < DATE '2026-01-01'
    AND p.status IN ('completed', 'paid')
  GROUP BY p.tenant_id
),
fee_by_tenant AS (
  SELECT
    p.tenant_id AS tenant_id,
    SUM({{divide_decimal(p.fee_amount, CASE WHEN p.currency_code = 'EUR' THEN 1 ELSE er.rate END)}}) AS fee_revenue_eur
  FROM payouts p
  LEFT JOIN exchange_rates er
    ON er.base_code = 'EUR'
   AND er.quote_code = p.currency_code
   AND er.as_of = CAST(p.paid_at AS date)
  WHERE p.paid_at >= DATE '2025-01-01'
    AND p.paid_at < DATE '2026-01-01'
    AND p.status IN ('completed', 'paid')
  GROUP BY p.tenant_id
),
tenant_grain AS (
  SELECT tenant_id FROM gross_by_tenant
  UNION
  SELECT tenant_id FROM fee_by_tenant
),
tenant_metrics AS (
  SELECT
    g0.tenant_id AS tenant_id,
    COALESCE(g1.gross_volume_eur, 0) AS gross_volume_eur,
    COALESCE(f1.fee_revenue_eur, 0) AS fee_revenue_eur
  FROM tenant_grain g0
  LEFT JOIN gross_by_tenant g1 ON g1.tenant_id = g0.tenant_id
  LEFT JOIN fee_by_tenant f1 ON f1.tenant_id = g0.tenant_id
),
totals AS (
  SELECT
    SUM(tm.gross_volume_eur) AS total_gross_eur,
    SUM(tm.fee_revenue_eur) AS total_fee_eur
  FROM tenant_metrics tm
)
SELECT
  ROW_NUMBER() OVER (ORDER BY tm.gross_volume_eur DESC NULLS FIRST, tm.tenant_id ASC NULLS LAST) AS rank,
  t.name AS merchant_name,
  t.industry AS industry_vertical,
  t.status AS tenant_status,
  tm.gross_volume_eur AS gross_volume_eur,
  100.0 * tm.gross_volume_eur / NULLIF(tot.total_gross_eur, 0) AS gross_volume_share_pct,
  100.0 * SUM(tm.gross_volume_eur) OVER (ORDER BY tm.gross_volume_eur DESC NULLS FIRST, tm.tenant_id ASC NULLS LAST ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW) / NULLIF(tot.total_gross_eur, 0) AS cumulative_gross_volume_share_pct,
  tm.fee_revenue_eur AS fee_revenue_eur,
  100.0 * tm.fee_revenue_eur / NULLIF(tot.total_fee_eur, 0) AS fee_revenue_share_pct
FROM tenant_metrics tm
JOIN tenants t ON t.id = tm.tenant_id
CROSS JOIN totals tot
ORDER BY tm.gross_volume_eur DESC NULLS FIRST, tm.tenant_id ASC NULLS LAST
{{fetch_first(25)}}
