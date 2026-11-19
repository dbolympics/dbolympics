SELECT
  m.merchant_name AS merchant_name,
  m.vertical AS vertical,
  m.tenant_status AS tenant_status,
  m.payment_count AS payment_count,
  m.gross_captured_eur AS gross_captured_eur,
  m.amount_refunded_eur AS amount_refunded_eur,
  {{divide_decimal(100.0 * m.amount_refunded_eur, NULLIF(m.gross_captured_eur,0))}} AS refund_rate_pct,
  100.0 * v.vertical_refund_rate AS vertical_avg_refund_rate_pct,
  {{divide_decimal(100.0 * m.amount_refunded_eur, NULLIF(m.gross_captured_eur,0))}} - 100.0 * v.vertical_refund_rate AS refund_rate_vs_vertical_avg_pp
FROM (
  SELECT
    p.tenant_id AS tenant_id,
    t.name AS merchant_name,
    t.industry AS vertical,
    t.status AS tenant_status,
    COUNT(*) AS payment_count,
    SUM(CAST({{divide_decimal(p.amount, er.rate)}} AS NUMERIC(18,6))) AS gross_captured_eur,
    SUM(CAST({{divide_decimal(p.amount_refunded, er.rate)}} AS NUMERIC(18,6))) AS amount_refunded_eur
  FROM payments p
  JOIN tenants t ON t.id = p.tenant_id
  JOIN exchange_rates er
    ON er.base_code = 'EUR'
    AND er.quote_code = p.currency_code
    AND er.as_of = CAST(p.captured_at AS date)
  WHERE p.captured_at >= DATE '2025-01-01'
    AND p.captured_at < DATE '2026-01-01'
    AND p.status IN ('captured','refunded','partially_refunded')
  GROUP BY p.tenant_id, t.name, t.industry, t.status
) m
JOIN (
  SELECT
    t.industry AS vertical,
    {{divide_decimal(SUM(CAST({{divide_decimal(p.amount_refunded, er.rate)}} AS NUMERIC(18,6))), NULLIF(SUM(CAST({{divide_decimal(p.amount, er.rate)}} AS NUMERIC(18,6))),0))}} AS vertical_refund_rate
  FROM payments p
  JOIN tenants t ON t.id = p.tenant_id
  JOIN exchange_rates er
    ON er.base_code = 'EUR'
    AND er.quote_code = p.currency_code
    AND er.as_of = CAST(p.captured_at AS date)
  WHERE p.captured_at >= DATE '2025-01-01'
    AND p.captured_at < DATE '2026-01-01'
    AND p.status IN ('captured','refunded','partially_refunded')
  GROUP BY t.industry
) v ON v.vertical = m.vertical
WHERE m.payment_count >= 50
ORDER BY refund_rate_pct DESC NULLS FIRST, m.merchant_name ASC NULLS LAST, m.tenant_id ASC NULLS LAST
{{fetch_first(20)}}
