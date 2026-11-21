WITH paid_payouts AS (
  SELECT p.tenant_id AS tenant_id, t.industry AS industry, p.fee_amount AS fee_amount, p.currency_code AS currency_code, p.paid_at AS paid_at,
    CASE WHEN p.paid_at >= DATE '2024-01-01' AND p.paid_at < DATE '2025-01-01' THEN 2024
         WHEN p.paid_at >= DATE '2025-01-01' AND p.paid_at < DATE '2026-01-01' THEN 2025
    END AS year
  FROM payouts p
  JOIN tenants t ON t.id = p.tenant_id
  WHERE p.status = 'paid'
    AND p.paid_at >= DATE '2024-01-01' AND p.paid_at < DATE '2026-01-01'
),
payout_fees_eur AS (
  SELECT pp.tenant_id AS tenant_id, pp.industry AS industry, pp.year AS year,
    CAST({{divide_decimal(pp.fee_amount, er.rate)}} AS NUMERIC(18,6)) AS fee_amount_eur
  FROM paid_payouts pp
  JOIN exchange_rates er
    ON er.base_code = 'EUR' AND er.quote_code = pp.currency_code AND er.as_of = CAST(pp.paid_at AS DATE)
  WHERE pp.year IS NOT NULL
),
tenant_year_revenue AS (
  SELECT tenant_id, COALESCE(NULLIF(TRIM(industry), ''), 'Unspecified') AS vertical, year,
    SUM(fee_amount_eur) AS fee_revenue_eur
  FROM payout_fees_eur
  GROUP BY tenant_id, vertical, year
),
vertical_year AS (
  SELECT vertical, year, SUM(fee_revenue_eur) AS fee_revenue_eur, COUNT(DISTINCT tenant_id) AS merchant_count
  FROM tenant_year_revenue
  GROUP BY vertical, year
),
vertical_pivot AS (
  SELECT vertical,
    SUM(CASE WHEN year=2024 THEN fee_revenue_eur ELSE 0 END) AS fee_revenue_2024,
    SUM(CASE WHEN year=2025 THEN fee_revenue_eur ELSE 0 END) AS fee_revenue_2025,
    SUM(CASE WHEN year=2024 THEN merchant_count ELSE 0 END) AS merchant_count_2024,
    SUM(CASE WHEN year=2025 THEN merchant_count ELSE 0 END) AS merchant_count_2025
  FROM vertical_year
  GROUP BY vertical
)
SELECT
  vertical,
  fee_revenue_2024 AS fee_revenue_2024_eur,
  fee_revenue_2025 AS fee_revenue_2025_eur,
  CASE WHEN fee_revenue_2024 = 0 THEN NULL
       ELSE {{divide_decimal(100.0 * (fee_revenue_2025 - fee_revenue_2024), fee_revenue_2024)}}
  END AS yoy_fee_revenue_growth_pct,
  merchant_count_2024,
  merchant_count_2025,
  merchant_count_2025 - merchant_count_2024 AS merchant_count_change
FROM vertical_pivot
ORDER BY fee_revenue_2025 DESC NULLS FIRST, vertical ASC NULLS LAST
