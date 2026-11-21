WITH t0 AS (
  SELECT
    p.id AS payment_id,
    p.captured_at AS captured_at,
    p.amount AS amount,
    p.amount_refunded AS amount_refunded,
    p.currency_code AS currency_code,
    CAST(EXTRACT(YEAR FROM p.captured_at) AS integer) AS cap_year,
    CAST(EXTRACT(QUARTER FROM p.captured_at) AS integer) AS cap_quarter
  FROM payments p
  WHERE p.status IN ('captured', 'refunded', 'partially_refunded')
    AND p.captured_at >= DATE '2024-01-01'
    AND p.captured_at < DATE '2026-01-01'
),
t1 AS (
  SELECT
    t0.payment_id AS payment_id,
    t0.cap_year AS cap_year,
    t0.cap_quarter AS cap_quarter,
    CAST({{divide_decimal(t0.amount, t0e.rate)}} AS NUMERIC(18,6)) AS amount_eur,
    CAST({{divide_decimal(t0.amount_refunded, t0e.rate)}} AS NUMERIC(18,6)) AS amount_refunded_eur
  FROM t0
  JOIN exchange_rates t0e
    ON t0e.base_code = 'EUR'
   AND t0e.quote_code = t0.currency_code
   AND t0e.as_of = CAST(t0.captured_at AS date)
),
t2 AS (
  SELECT
    t1.cap_year AS quarter_year,
    t1.cap_quarter AS quarter_num,
    COUNT(*) AS payment_count,
    SUM(t1.amount_eur) AS gross_captured_eur,
    SUM(t1.amount_refunded_eur) AS amount_refunded_eur
  FROM t1
  GROUP BY t1.cap_year, t1.cap_quarter
)
SELECT
  CONCAT(CAST(t2.quarter_year AS varchar), '-Q', CAST(t2.quarter_num AS varchar)) AS quarter,
  t2.payment_count AS payment_count,
  t2.gross_captured_eur AS gross_captured_eur,
  t2.amount_refunded_eur AS amount_refunded_eur,
  {{divide_decimal(t2.amount_refunded_eur, NULLIF(t2.gross_captured_eur, 0))}} * 100 AS refund_rate_pct,
  {{divide_decimal(t4.amount_refunded_eur, NULLIF(t4.gross_captured_eur, 0))}} * 100 AS refund_rate_same_quarter_prior_year_pct
FROM t2
LEFT JOIN t2 t4
  ON t4.quarter_year = t2.quarter_year - 1
 AND t4.quarter_num = t2.quarter_num
ORDER BY t2.quarter_year ASC NULLS LAST, t2.quarter_num ASC NULLS LAST
