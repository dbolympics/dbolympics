WITH converted AS (
  SELECT
    p.status AS status,
    p.paid_at AS paid_at,
    p.arrival_date AS arrival_date,
    p.currency_code AS currency_code,
    p.gross_amount AS gross_amount,
    p.fee_amount AS fee_amount,
    er.rate AS rate
  FROM payouts p
  LEFT JOIN exchange_rates er
    ON er.base_code = 'EUR'
    AND er.quote_code = p.currency_code
    AND er.as_of = CAST(p.paid_at AS date)
)
SELECT
  status,
  COUNT(*) AS total_payout_count,
  COUNT(*) FILTER (WHERE paid_at >= DATE '2025-01-01' AND paid_at < DATE '2026-01-01') AS count_paid_in_window,
  COUNT(*) FILTER (WHERE paid_at IS NULL) AS count_paid_at_null,
  SUM(CASE WHEN paid_at >= DATE '2025-01-01' AND paid_at < DATE '2026-01-01' THEN CAST({{divide_decimal(fee_amount, rate)}} AS NUMERIC(18,6)) END) AS fee_revenue_eur,
  SUM(CASE WHEN paid_at >= DATE '2025-01-01' AND paid_at < DATE '2026-01-01' THEN CAST({{divide_decimal(gross_amount, rate)}} AS NUMERIC(18,6)) END) AS gross_volume_eur,
  MIN(paid_at) AS earliest_paid_at,
  MAX(paid_at) AS latest_paid_at,
  MIN(arrival_date) AS earliest_arrival_date,
  MAX(arrival_date) AS latest_arrival_date
FROM converted
GROUP BY status
ORDER BY total_payout_count DESC NULLS FIRST, status NULLS LAST
