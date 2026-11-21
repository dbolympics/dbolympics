WITH payouts_with_rate AS (
  SELECT
    p.id AS id,
    p.currency_code AS currency_code,
    p.gross_amount AS gross_amount,
    p.fee_amount AS fee_amount,
    p.net_amount AS net_amount,
    p.paid_at AS paid_at,
    CAST(p.paid_at AS DATE) AS paid_date,
    CASE WHEN p.currency_code = 'EUR' THEN 1.0 ELSE er.rate END AS eur_rate
  FROM payouts p
  LEFT JOIN exchange_rates er
    ON er.base_code = 'EUR'
   AND er.quote_code = p.currency_code
   AND er.as_of = CAST(p.paid_at AS DATE)
  WHERE p.status IN ('paid', 'completed')
),
payouts_2025_converted AS (
  SELECT
    pw.id AS id,
    pw.paid_date AS paid_date,
    CAST({{divide_decimal(pw.gross_amount, pw.eur_rate)}} AS NUMERIC(18,6)) AS gross_eur,
    CAST({{divide_decimal(pw.fee_amount, pw.eur_rate)}} AS NUMERIC(18,6)) AS fee_eur,
    CAST({{divide_decimal(pw.net_amount, pw.eur_rate)}} AS NUMERIC(18,6)) AS net_eur
  FROM payouts_with_rate pw
  WHERE pw.paid_date >= DATE '2025-01-01' AND pw.paid_date < DATE '2026-01-01'
),
payouts_2024_converted AS (
  SELECT
    pw.id AS id,
    pw.paid_date AS paid_date,
    CAST({{divide_decimal(pw.fee_amount, pw.eur_rate)}} AS NUMERIC(18,6)) AS fee_eur
  FROM payouts_with_rate pw
  WHERE pw.paid_date >= DATE '2024-01-01' AND pw.paid_date < DATE '2025-01-01'
),
monthly_2025 AS (
  SELECT
    cd.month_label AS month_label,
    cd.month_num AS month_num,
    COUNT(pc.id) AS payout_count,
    SUM(pc.gross_eur) AS gross_volume_eur,
    SUM(pc.fee_eur) AS fee_revenue_eur,
    SUM(pc.net_eur) AS net_paid_out_eur
  FROM payouts_2025_converted pc
  JOIN calendar_days cd ON cd.calendar_date = pc.paid_date
  GROUP BY cd.month_label, cd.month_num
),
monthly_2024_fee AS (
  SELECT
    cd.month_num AS month_num,
    SUM(pc.fee_eur) AS fee_revenue_prior_year_eur
  FROM payouts_2024_converted pc
  JOIN calendar_days cd ON cd.calendar_date = pc.paid_date
  GROUP BY cd.month_num
),
monthly_combined AS (
  SELECT
    m.month_label AS month_label,
    m.month_num AS month_num,
    m.payout_count AS payout_count,
    m.gross_volume_eur AS gross_volume_eur,
    m.fee_revenue_eur AS fee_revenue_eur,
    m.net_paid_out_eur AS net_paid_out_eur,
    CASE WHEN m.gross_volume_eur = 0 THEN NULL ELSE ({{divide_decimal(m.fee_revenue_eur, m.gross_volume_eur)}}) * 100 END AS fee_rate_pct,
    py.fee_revenue_prior_year_eur AS fee_revenue_prior_year_eur
  FROM monthly_2025 m
  LEFT JOIN monthly_2024_fee py ON py.month_num = m.month_num
),
total_row AS (
  SELECT
    'TOTAL' AS month_label,
    13 AS month_num,
    SUM(payout_count) AS payout_count,
    SUM(gross_volume_eur) AS total_gross_volume_eur,
    SUM(fee_revenue_eur) AS total_fee_revenue_eur,
    SUM(net_paid_out_eur) AS net_paid_out_eur,
    CASE WHEN SUM(gross_volume_eur) = 0 THEN NULL ELSE ({{divide_decimal(SUM(fee_revenue_eur), SUM(gross_volume_eur))}}) * 100 END AS fee_rate_pct,
    SUM(fee_revenue_prior_year_eur) AS fee_revenue_prior_year_eur
  FROM monthly_combined
)
SELECT
  month_label AS month,
  payout_count,
  gross_volume_eur AS gross_volume_eur,
  fee_revenue_eur AS fee_revenue_eur,
  net_paid_out_eur AS net_paid_out_eur,
  fee_rate_pct AS fee_rate_pct,
  fee_revenue_prior_year_eur AS fee_revenue_prior_year_eur
FROM (
  SELECT * FROM monthly_combined
  UNION ALL
  SELECT * FROM total_row
) x
ORDER BY month_num NULLS LAST, month_label NULLS LAST
