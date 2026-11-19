WITH payout_eur AS (
  SELECT p.tenant_id AS tenant_id,
         CAST({{divide_decimal(p.gross_amount, er.rate)}} AS NUMERIC(18,6)) AS gross_eur,
         CAST({{divide_decimal(p.fee_amount, er.rate)}} AS NUMERIC(18,6)) AS fee_eur,
         CAST({{divide_decimal(p.net_amount, er.rate)}} AS NUMERIC(18,6)) AS net_eur
  FROM payouts p
  JOIN exchange_rates er
    ON er.base_code = 'EUR'
   AND er.quote_code = p.currency_code
   AND er.as_of = CAST(p.paid_at AS date)
  WHERE p.paid_at >= DATE '2025-01-01'
    AND p.paid_at < DATE '2026-01-01'
    AND p.status NOT IN ('failed','reversed','cancelled','void')
),
agg AS (
  SELECT tenant_id,
         SUM(gross_eur) AS gross_volume_eur,
         SUM(fee_eur) AS fee_revenue_eur,
         SUM(net_eur) AS net_paid_eur
  FROM payout_eur
  GROUP BY tenant_id
),
ranked AS (
  SELECT a.tenant_id AS tenant_id,
         a.gross_volume_eur AS gross_volume_eur,
         a.fee_revenue_eur AS fee_revenue_eur,
         a.net_paid_eur AS net_paid_eur,
         SUM(a.fee_revenue_eur) OVER () AS total_fee_eur
  FROM agg a
)
SELECT
  t.name AS merchant_name,
  t.industry AS vertical,
  r.gross_volume_eur AS gross_payment_volume_eur,
  r.fee_revenue_eur AS fee_revenue_eur,
  r.net_paid_eur AS net_paid_eur,
  {{divide_decimal(100.0 * r.fee_revenue_eur, NULLIF(r.total_fee_eur,0))}} AS fee_share_pct,
  {{divide_decimal(100.0 * SUM(r.fee_revenue_eur) OVER (ORDER BY r.fee_revenue_eur DESC NULLS FIRST, t.name ASC NULLS LAST, t.id ASC NULLS LAST ROWS UNBOUNDED PRECEDING), NULLIF(r.total_fee_eur,0))}} AS cumulative_fee_share_pct
FROM ranked r
JOIN tenants t ON t.id = r.tenant_id
ORDER BY r.fee_revenue_eur DESC NULLS FIRST, t.name ASC NULLS LAST, t.id ASC NULLS LAST
{{fetch_first(50)}}
