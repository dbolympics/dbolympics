WITH pop AS (
  SELECT currency_code, amount, captured_at
  FROM payments
  WHERE status IN ('captured','refunded','partially_refunded')
    AND captured_at >= DATE '2025-01-01' AND captured_at < DATE '2026-01-01'
),
naive AS (
  SELECT p.currency_code AS currency_code, SUM(CAST({{divide_decimal(p.amount, er.rate)}} AS NUMERIC(18,6))) AS naive_eur
  FROM pop p
  JOIN exchange_rates er
    ON er.base_code = 'EUR'
   AND er.quote_code = p.currency_code
   AND er.as_of = CAST(p.captured_at AS date)
  GROUP BY p.currency_code
),
correct AS (
  SELECT p.currency_code AS currency_code,
    SUM(CASE WHEN p.currency_code = 'EUR' THEN p.amount ELSE CAST({{divide_decimal(p.amount, er.rate)}} AS NUMERIC(18,6)) END) AS correct_eur
  FROM pop p
  LEFT JOIN exchange_rates er
    ON er.base_code = 'EUR'
   AND er.quote_code = p.currency_code
   AND er.as_of = CAST(p.captured_at AS date)
  GROUP BY p.currency_code
)
SELECT
  c.currency_code AS currency_code,
  COALESCE(n.naive_eur, 0) AS total_2025_revenue_naive_eur,
  c.correct_eur AS total_2025_revenue_correct_eur,
  c.correct_eur - COALESCE(n.naive_eur, 0) AS shortfall_eur,
  {{divide_decimal((c.correct_eur - COALESCE(n.naive_eur, 0)), c.correct_eur)}} * 100 AS shortfall_pct
FROM correct c
LEFT JOIN naive n ON n.currency_code = c.currency_code
ORDER BY c.correct_eur DESC NULLS FIRST, c.currency_code NULLS LAST
