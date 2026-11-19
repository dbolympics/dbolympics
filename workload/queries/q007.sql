WITH payout_eur AS (
  SELECT p.tenant_id AS tenant_id,
         CAST({{divide_decimal(p.gross_amount, er.rate)}} AS NUMERIC(18,6)) AS gross_eur,
         CAST({{divide_decimal(p.fee_amount, er.rate)}} AS NUMERIC(18,6)) AS fee_eur
  FROM payouts p
  JOIN exchange_rates er
    ON er.base_code = 'EUR' AND er.quote_code = p.currency_code AND er.as_of = CAST(p.paid_at AS DATE)
  WHERE p.status = 'paid' AND p.paid_at >= DATE '2025-01-01' AND p.paid_at < DATE '2026-01-01'
),
tenant_agg AS (
  SELECT tenant_id, SUM(gross_eur) AS gross_eur, SUM(fee_eur) AS fee_eur
  FROM payout_eur
  GROUP BY tenant_id
)
SELECT
  COALESCE(NULLIF(TRIM(t.industry), ''), 'Unspecified') AS vertical,
  COUNT(DISTINCT ta.tenant_id) AS merchant_count,
  SUM(ta.gross_eur) AS gross_payment_volume_eur,
  SUM(ta.fee_eur) AS fee_revenue_eur,
  ({{divide_decimal(SUM(ta.fee_eur), COUNT(DISTINCT ta.tenant_id))}}) AS avg_fee_revenue_per_merchant_eur,
  ({{divide_decimal(100.0 * SUM(ta.fee_eur), SUM(SUM(ta.fee_eur)) OVER ())}}) AS share_of_total_fee_revenue_pct
FROM tenant_agg ta
JOIN tenants t ON t.id = ta.tenant_id
GROUP BY vertical
ORDER BY fee_revenue_eur DESC NULLS FIRST, vertical ASC NULLS LAST
