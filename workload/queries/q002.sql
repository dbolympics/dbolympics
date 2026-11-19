WITH payout_fees_eur AS (
  SELECT
    p.tenant_id AS tenant_id,
    p.paid_at AS paid_at,
    p.fee_amount AS fee_amount,
    p.currency_code AS currency_code,
    er.rate AS rate,
    CAST({{divide_decimal(p.fee_amount, er.rate)}} AS NUMERIC(18,6)) AS fee_amount_eur
  FROM payouts p
  JOIN exchange_rates er
    ON er.base_code = 'EUR'
   AND er.quote_code = p.currency_code
   AND er.as_of = CAST(p.paid_at AS date)
  WHERE p.paid_at IS NOT NULL
    AND p.paid_at >= DATE '2024-01-01'
    AND p.paid_at < DATE '2026-01-01'
),
quarterly AS (
  SELECT
    cd.year_num AS year_num,
    cd.quarter_num AS quarter_num,
    cd.year_num || '-Q' || cd.quarter_num AS quarter_label,
    pf.tenant_id AS tenant_id,
    SUM(pf.fee_amount_eur) AS fee_eur
  FROM payout_fees_eur pf
  JOIN calendar_days cd ON cd.calendar_date = CAST(pf.paid_at AS date)
  GROUP BY 1, 2, 3, 4
),
ranked AS (
  SELECT
    quarterly.*,
    ROW_NUMBER() OVER (PARTITION BY quarter_label ORDER BY fee_eur DESC NULLS FIRST, tenant_id NULLS LAST) AS rnk
  FROM quarterly
),
quarter_totals AS (
  SELECT
    quarter_label,
    year_num,
    quarter_num,
    COUNT(DISTINCT tenant_id) AS active_merchants,
    SUM(fee_eur) AS total_fee_eur
  FROM quarterly
  GROUP BY 1, 2, 3
),
top_sums AS (
  SELECT
    quarter_label,
    SUM(fee_eur) FILTER (WHERE rnk <= 5) AS top5_fee_eur,
    SUM(fee_eur) FILTER (WHERE rnk <= 10) AS top10_fee_eur
  FROM ranked
  GROUP BY 1
)
SELECT
  qt.quarter_label AS quarter,
  qt.active_merchants AS active_merchants,
  qt.total_fee_eur AS total_fee_revenue_eur,
  ts.top5_fee_eur AS top5_fee_revenue_eur,
  {{divide_decimal(100.0 * ts.top5_fee_eur, NULLIF(qt.total_fee_eur, 0))}} AS top5_share_pct,
  ts.top10_fee_eur AS top10_fee_revenue_eur,
  {{divide_decimal(100.0 * ts.top10_fee_eur, NULLIF(qt.total_fee_eur, 0))}} AS top10_share_pct
FROM quarter_totals qt
JOIN top_sums ts ON ts.quarter_label = qt.quarter_label
ORDER BY qt.year_num NULLS LAST, qt.quarter_num NULLS LAST
