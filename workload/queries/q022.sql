SELECT
  COALESCE(t.industry, 'Unknown') AS vertical,
  'Q' || cd.quarter_num AS quarter,
  COUNT(DISTINCT t.id) AS merchant_count,
  COUNT(*) AS payment_count,
  SUM(CAST({{divide_decimal(p.amount, er.rate)}} AS NUMERIC(18,6))) AS gross_captured_eur,
  SUM(CAST({{divide_decimal(p.amount_refunded, er.rate)}} AS NUMERIC(18,6))) AS amount_refunded_eur,
  {{divide_decimal(100.0 * SUM(CAST({{divide_decimal(p.amount_refunded, er.rate)}} AS NUMERIC(18,6))), NULLIF(SUM(CAST({{divide_decimal(p.amount, er.rate)}} AS NUMERIC(18,6))), 0))}} AS refund_rate_pct
FROM payments p
JOIN tenants t ON t.id = p.tenant_id
JOIN calendar_days cd ON cd.calendar_date = CAST(p.captured_at AS date)
JOIN exchange_rates er
  ON er.base_code = 'EUR'
 AND er.quote_code = p.currency_code
 AND er.as_of = CAST(p.captured_at AS date)
WHERE p.status IN ('captured', 'refunded', 'partially_refunded')
  AND p.captured_at >= DATE '2025-01-01'
  AND p.captured_at < DATE '2026-01-01'
GROUP BY 1, 2
ORDER BY vertical ASC NULLS LAST, quarter ASC NULLS LAST
