WITH quarters AS (
  SELECT DISTINCT year_num, quarter_num
  FROM calendar_days
  WHERE year_num IN (2024, 2025)
),
exch AS (
  SELECT quote_code, as_of, rate
  FROM exchange_rates
  WHERE base_code = 'EUR'
),
payment_eur AS (
  SELECT
    p.id AS payment_id,
    p.tenant_id AS tenant_id,
    t.industry AS industry,
    cd.year_num AS year_num,
    cd.quarter_num AS quarter_num,
    CAST({{divide_decimal(p.amount, er.rate)}} AS NUMERIC(18,6)) AS amount_eur,
    CAST({{divide_decimal(p.amount_refunded, er.rate)}} AS NUMERIC(18,6)) AS amount_refunded_eur
  FROM payments p
  JOIN tenants t ON t.id = p.tenant_id
  JOIN calendar_days cd ON cd.calendar_date = CAST(p.captured_at AS date)
  JOIN exch er ON er.quote_code = p.currency_code AND er.as_of = cd.calendar_date
  WHERE p.status IN ('captured','partially_refunded','refunded')
    AND p.captured_at >= TIMESTAMP '2024-01-01'
    AND p.captured_at < TIMESTAMP '2026-01-01'
),
apparel_agg AS (
  SELECT year_num, quarter_num,
    COUNT(DISTINCT tenant_id) AS merchant_count,
    COUNT(*) AS payment_count,
    SUM(amount_eur) AS gross_captured_eur,
    SUM(amount_refunded_eur) AS amount_refunded_eur
  FROM payment_eur
  WHERE industry = 'Apparel & Footwear'
  GROUP BY year_num, quarter_num
),
company_agg AS (
  SELECT year_num, quarter_num,
    SUM(amount_eur) AS gross_captured_eur,
    SUM(amount_refunded_eur) AS amount_refunded_eur
  FROM payment_eur
  GROUP BY year_num, quarter_num
)
SELECT
  q.year_num || '-Q' || q.quarter_num AS quarter,
  COALESCE(a.merchant_count, 0) AS merchant_count,
  COALESCE(a.payment_count, 0) AS payment_count,
  COALESCE(a.gross_captured_eur,0) AS gross_captured_eur,
  COALESCE(a.amount_refunded_eur,0) AS amount_refunded_eur,
  CASE WHEN COALESCE(a.gross_captured_eur,0) = 0 THEN NULL ELSE {{divide_decimal(a.amount_refunded_eur, a.gross_captured_eur)}} * 100 END AS refund_rate_pct,
  CASE WHEN COALESCE(c.gross_captured_eur,0) = 0 THEN NULL ELSE {{divide_decimal(c.amount_refunded_eur, c.gross_captured_eur)}} * 100 END AS company_avg_refund_rate_pct
FROM quarters q
LEFT JOIN apparel_agg a ON a.year_num = q.year_num AND a.quarter_num = q.quarter_num
LEFT JOIN company_agg c ON c.year_num = q.year_num AND c.quarter_num = q.quarter_num
ORDER BY q.year_num NULLS LAST, q.quarter_num NULLS LAST
