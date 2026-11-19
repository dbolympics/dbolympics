SELECT
  p.currency_code AS currency_code,
  COUNT(*) AS payout_count,
  SUM(p.gross_amount) AS gross_volume_local_sum,
  SUM(CASE WHEN p.currency_code = 'EUR' THEN CAST(p.gross_amount AS NUMERIC(18,6))
           WHEN er.rate IS NOT NULL THEN CAST({{divide_decimal(p.gross_amount, er.rate)}} AS NUMERIC(18,6))
           ELSE 0 END) AS gross_volume_eur,
  SUM(CASE WHEN p.currency_code = 'EUR' THEN CAST(p.fee_amount AS NUMERIC(18,6))
           WHEN er.rate IS NOT NULL THEN CAST({{divide_decimal(p.fee_amount, er.rate)}} AS NUMERIC(18,6))
           ELSE 0 END) AS fee_revenue_eur,
  COUNT(CASE WHEN p.currency_code = 'EUR' OR er.rate IS NOT NULL THEN 1 END) AS payout_count_with_matched_fx_rate,
  COUNT(CASE WHEN p.currency_code <> 'EUR' AND er.rate IS NULL THEN 1 END) AS payout_count_missing_fx_rate,
  AVG(CASE WHEN p.currency_code = 'EUR' THEN 1.0
           WHEN er.rate IS NOT NULL THEN er.rate END) AS avg_eur_rate_used
FROM payouts p
LEFT JOIN exchange_rates er
  ON er.base_code = 'EUR'
  AND er.quote_code = p.currency_code
  AND er.as_of = CAST(p.paid_at AS date)
WHERE p.status IN ('paid','completed')
  AND p.paid_at >= DATE '2025-01-01'
  AND p.paid_at < DATE '2026-01-01'
GROUP BY p.currency_code
ORDER BY payout_count DESC NULLS FIRST, p.currency_code ASC NULLS LAST
