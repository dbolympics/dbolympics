WITH months AS (
  SELECT DISTINCT t0.month_num AS month_num, t0.month_label AS month_label
  FROM calendar_days t0
  WHERE t0.year_num = 2025
),
converted_payouts AS (
  SELECT
    t0.id AS payout_id,
    t2.year_num AS year_num,
    t2.month_num AS month_num,
    CAST({{divide_decimal(t0.gross_amount, t1.rate)}} AS NUMERIC(18,6)) AS gross_eur,
    CAST({{divide_decimal(t0.fee_amount, t1.rate)}} AS NUMERIC(18,6)) AS fee_eur,
    CAST({{divide_decimal(t0.net_amount, t1.rate)}} AS NUMERIC(18,6)) AS net_eur
  FROM payouts t0
  JOIN exchange_rates t1
    ON t1.base_code = 'EUR'
   AND t1.quote_code = t0.currency_code
   AND t1.as_of = CAST(t0.paid_at AS date)
  JOIN calendar_days t2
    ON t2.calendar_date = CAST(t0.paid_at AS date)
  WHERE t0.paid_at IS NOT NULL
    AND t0.status IN ('paid', 'completed')
),
current_year AS (
  SELECT
    t0.month_num AS month_num,
    COUNT(*) AS payout_count,
    SUM(t0.gross_eur) AS gross_eur_total,
    SUM(t0.fee_eur) AS fee_eur_total,
    SUM(t0.net_eur) AS net_eur_total
  FROM converted_payouts t0
  WHERE t0.year_num = 2025
  GROUP BY t0.month_num
),
prior_year AS (
  SELECT
    t0.month_num AS month_num,
    SUM(t0.fee_eur) AS fee_eur_total_prior
  FROM converted_payouts t0
  WHERE t0.year_num = 2024
  GROUP BY t0.month_num
)
SELECT
  t0.month_label AS month,
  COALESCE(t1.payout_count, 0) AS payout_count,
  COALESCE(t1.gross_eur_total, 0) AS gross_volume_eur,
  COALESCE(t1.fee_eur_total, 0) AS fee_revenue_eur,
  COALESCE(t1.net_eur_total, 0) AS net_paid_out_eur,
  {{divide_decimal(COALESCE(t1.fee_eur_total, 0), NULLIF(t1.gross_eur_total, 0))}} * 100 AS fee_rate_pct,
  COALESCE(t2.fee_eur_total_prior, 0) AS fee_revenue_prior_year_eur
FROM months t0
LEFT JOIN current_year t1 ON t1.month_num = t0.month_num
LEFT JOIN prior_year t2 ON t2.month_num = t0.month_num
ORDER BY t0.month_num NULLS LAST, t0.month_label NULLS LAST
