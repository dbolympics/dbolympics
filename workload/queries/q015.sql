WITH payout_eur AS (
  SELECT p.tenant_id AS tenant_id,
         EXTRACT(YEAR FROM p.paid_at) AS yr,
         CASE WHEN p.currency_code = 'EUR' THEN p.gross_amount
              ELSE CAST({{divide_decimal(p.gross_amount, er.rate)}} AS NUMERIC(18,6)) END AS gross_eur,
         CASE WHEN p.currency_code = 'EUR' THEN p.fee_amount
              ELSE CAST({{divide_decimal(p.fee_amount, er.rate)}} AS NUMERIC(18,6)) END AS fee_eur
  FROM payouts p
  LEFT JOIN exchange_rates er
    ON er.base_code = 'EUR'
   AND er.quote_code = p.currency_code
   AND er.as_of = CAST(p.paid_at AS date)
  WHERE p.status IN ('completed', 'paid')
    AND p.paid_at >= DATE '2024-01-01'
    AND p.paid_at < DATE '2026-01-01'
),
tenant_year AS (
  SELECT tenant_id, yr, SUM(gross_eur) AS gross_eur, SUM(fee_eur) AS fee_eur
  FROM payout_eur
  GROUP BY tenant_id, yr
),
ranked AS (
  SELECT ty.*, ROW_NUMBER() OVER (PARTITION BY yr ORDER BY gross_eur DESC NULLS FIRST, tenant_id NULLS LAST) AS rnk
  FROM tenant_year ty
),
year_totals AS (
  SELECT yr, COUNT(*) AS active_merchants, SUM(gross_eur) AS total_gross_eur, SUM(fee_eur) AS total_fee_eur
  FROM tenant_year
  GROUP BY yr
),
top_agg AS (
  SELECT yr,
    SUM(CASE WHEN rnk <= 5 THEN gross_eur ELSE 0 END) AS top5_gross,
    SUM(CASE WHEN rnk <= 5 THEN fee_eur ELSE 0 END) AS top5_fee,
    SUM(CASE WHEN rnk <= 10 THEN gross_eur ELSE 0 END) AS top10_gross,
    SUM(CASE WHEN rnk <= 10 THEN fee_eur ELSE 0 END) AS top10_fee
  FROM ranked
  GROUP BY yr
)
SELECT
  yt.yr AS year,
  yt.active_merchants AS active_merchant_count,
  yt.total_gross_eur AS total_gross_volume_eur,
  ta.top5_gross AS top5_gross_volume_eur,
  {{divide_decimal(100.0 * ta.top5_gross, NULLIF(yt.total_gross_eur, 0))}} AS top5_share_pct,
  ta.top10_gross AS top10_gross_volume_eur,
  {{divide_decimal(100.0 * ta.top10_gross, NULLIF(yt.total_gross_eur, 0))}} AS top10_share_pct,
  {{divide_decimal(100.0 * ta.top10_fee, NULLIF(yt.total_fee_eur, 0))}} AS top10_fee_share_pct
FROM year_totals yt
JOIN top_agg ta ON ta.yr = yt.yr
ORDER BY yt.yr ASC NULLS LAST
