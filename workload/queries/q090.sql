WITH months AS (
  SELECT DISTINCT month_start AS month
  FROM calendar_days
  WHERE month_start >= DATE '2023-01-01' AND month_start <= DATE '2025-12-01'
),
payout_agg AS (
  SELECT
    CAST({{date_trunc('month', COALESCE(p.paid_at, CAST(p.arrival_date AS timestamp)))}} AS date) AS month,
    SUM(CAST(p.gross_amount / er.rate AS NUMERIC(18,6))) AS gross_eur,
    SUM(CAST(p.fee_amount / er.rate AS NUMERIC(18,6))) AS fee_eur,
    SUM(CAST(p.net_amount / er.rate AS NUMERIC(18,6))) AS net_eur
  FROM payouts p
  JOIN exchange_rates er
    ON er.base_code = 'EUR'
   AND er.quote_code = p.currency_code
   AND er.as_of = COALESCE(CAST(p.paid_at AS date), p.arrival_date)
  WHERE COALESCE(p.paid_at, CAST(p.arrival_date AS timestamp)) IS NOT NULL
  GROUP BY 1
),
refund_agg AS (
  SELECT
    CAST({{date_trunc('month', pr.processed_at)}} AS date) AS month,
    SUM(CAST(pr.amount / er.rate AS NUMERIC(18,6))) AS refunds_eur
  FROM payment_refunds pr
  JOIN exchange_rates er
    ON er.base_code = 'EUR'
   AND er.quote_code = pr.currency_code
   AND er.as_of = CAST(pr.processed_at AS date)
  WHERE pr.status = 'succeeded'
  GROUP BY 1
)
SELECT
  {{year_month(m.month)}} AS month_label,
  COALESCE(pa.gross_eur,0) AS payout_gross_eur,
  COALESCE(pa.fee_eur,0) AS payout_fee_eur,
  COALESCE(pa.net_eur,0) AS payout_net_eur,
  COALESCE(pa.net_eur,0) - (COALESCE(pa.gross_eur,0) - COALESCE(pa.fee_eur,0)) AS net_check_diff_eur,
  COALESCE(ra.refunds_eur,0) AS refunds_processed_eur,
  COALESCE(pa.net_eur,0) - (COALESCE(pa.gross_eur,0) - COALESCE(pa.fee_eur,0) - COALESCE(ra.refunds_eur,0)) AS net_minus_refunds_diff_eur
FROM months m
LEFT JOIN payout_agg pa ON pa.month = m.month
LEFT JOIN refund_agg ra ON ra.month = m.month
ORDER BY m.month NULLS LAST
