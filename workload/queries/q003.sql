WITH tenant_vertical AS (
  SELECT t0.id AS tenant_id,
         COALESCE(NULLIF(TRIM(t0.industry), ''), 'Unspecified') AS vertical
  FROM tenants t0
),
fx AS (
  SELECT er0.quote_code AS quote_code,
         er0.as_of AS as_of,
         er0.rate AS rate
  FROM exchange_rates er0
  WHERE er0.base_code = 'EUR'
),
qualifying_payouts AS (
  SELECT p0.id AS payout_id,
         p0.tenant_id AS tenant_id,
         p0.currency_code AS currency_code,
         p0.gross_amount AS gross_amount,
         p0.fee_amount AS fee_amount,
         p0.paid_at AS paid_at,
         COALESCE(fx0.rate, 1.0) AS eur_rate
  FROM payouts p0
  LEFT JOIN fx fx0
    ON fx0.quote_code = p0.currency_code
   AND fx0.as_of = CAST(p0.paid_at AS date)
  WHERE p0.status = 'paid'
    AND p0.paid_at >= DATE '2025-01-01'
    AND p0.paid_at < DATE '2026-01-01'
),
verticals AS (
  SELECT DISTINCT tv0.vertical AS vertical
  FROM tenant_vertical tv0
  JOIN qualifying_payouts qp0 ON qp0.tenant_id = tv0.tenant_id
),
merchant_counts AS (
  SELECT tv0.vertical AS vertical,
         COUNT(DISTINCT qp0.tenant_id) AS merchant_count
  FROM qualifying_payouts qp0
  JOIN tenant_vertical tv0 ON tv0.tenant_id = qp0.tenant_id
  GROUP BY tv0.vertical
),
gross_volume AS (
  SELECT tv0.vertical AS vertical,
         SUM(CAST({{divide_decimal(qp0.gross_amount, qp0.eur_rate)}} AS NUMERIC(18,6))) AS gross_volume_eur
  FROM qualifying_payouts qp0
  JOIN tenant_vertical tv0 ON tv0.tenant_id = qp0.tenant_id
  GROUP BY tv0.vertical
),
fee_revenue AS (
  SELECT tv0.vertical AS vertical,
         SUM(CAST({{divide_decimal(qp0.fee_amount, qp0.eur_rate)}} AS NUMERIC(18,6))) AS fee_revenue_eur
  FROM qualifying_payouts qp0
  JOIN tenant_vertical tv0 ON tv0.tenant_id = qp0.tenant_id
  GROUP BY tv0.vertical
),
total_fee AS (
  SELECT SUM(fr0.fee_revenue_eur) AS total_fee_revenue_eur
  FROM fee_revenue fr0
)
SELECT
  v0.vertical AS vertical,
  COALESCE(mc0.merchant_count, 0) AS merchant_count,
  COALESCE(gv0.gross_volume_eur, 0) AS gross_payment_volume_eur,
  COALESCE(fr0.fee_revenue_eur, 0) AS fee_revenue_eur,
  {{divide_decimal(COALESCE(fr0.fee_revenue_eur, 0), NULLIF(COALESCE(mc0.merchant_count, 0), 0))}} AS avg_fee_revenue_per_merchant_eur,
  {{divide_decimal(100.0 * COALESCE(fr0.fee_revenue_eur, 0), NULLIF(t0.total_fee_revenue_eur, 0))}} AS pct_of_total_fee_revenue
FROM verticals v0
LEFT JOIN merchant_counts mc0 ON mc0.vertical = v0.vertical
LEFT JOIN gross_volume gv0 ON gv0.vertical = v0.vertical
LEFT JOIN fee_revenue fr0 ON fr0.vertical = v0.vertical
CROSS JOIN total_fee t0
ORDER BY fee_revenue_eur DESC NULLS FIRST, vertical ASC NULLS LAST
