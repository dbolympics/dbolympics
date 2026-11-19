WITH t1 AS (
  SELECT
    t10.tenant_id AS tenant_id,
    SUM(CAST({{divide_decimal(t10.amount, t11.rate)}} AS NUMERIC(18,6))) AS captured_eur_q4,
    COUNT(DISTINCT t10.order_id) AS order_count_q4
  FROM payments AS t10
  JOIN exchange_rates AS t11
    ON t11.base_code = 'EUR'
   AND t11.quote_code = t10.currency_code
   AND t11.as_of = CAST(t10.captured_at AS date)
  WHERE t10.status IN ('captured', 'partially_refunded', 'refunded')
    AND t10.captured_at >= DATE '2025-10-01'
    AND t10.captured_at < DATE '2026-01-01'
  GROUP BY t10.tenant_id
),
t2 AS (
  SELECT
    t20.tenant_id AS tenant_id,
    SUM(CAST({{divide_decimal(t20.amount, t21.rate)}} AS NUMERIC(18,6))) AS captured_eur_baseline
  FROM payments AS t20
  JOIN exchange_rates AS t21
    ON t21.base_code = 'EUR'
   AND t21.quote_code = t20.currency_code
   AND t21.as_of = CAST(t20.captured_at AS date)
  WHERE t20.status IN ('captured', 'partially_refunded', 'refunded')
    AND t20.captured_at >= DATE '2025-01-01'
    AND t20.captured_at < DATE '2025-10-01'
  GROUP BY t20.tenant_id
),
t3 AS (
  SELECT
    t30.tenant_id AS tenant_id,
    SUM(CAST({{divide_decimal(t30.amount, t31.rate)}} AS NUMERIC(18,6))) AS refund_eur_q4
  FROM payment_refunds AS t30
  JOIN exchange_rates AS t31
    ON t31.base_code = 'EUR'
   AND t31.quote_code = t30.currency_code
   AND t31.as_of = CAST(t30.processed_at AS date)
  WHERE t30.status = 'succeeded'
    AND t30.processed_at >= DATE '2025-10-01'
    AND t30.processed_at < DATE '2026-01-01'
  GROUP BY t30.tenant_id
),
t4 AS (
  SELECT
    t40.tenant_id AS tenant_id,
    SUM(CAST({{divide_decimal(t40.amount, t41.rate)}} AS NUMERIC(18,6))) AS refund_eur_baseline
  FROM payment_refunds AS t40
  JOIN exchange_rates AS t41
    ON t41.base_code = 'EUR'
   AND t41.quote_code = t40.currency_code
   AND t41.as_of = CAST(t40.processed_at AS date)
  WHERE t40.status = 'succeeded'
    AND t40.processed_at >= DATE '2025-01-01'
    AND t40.processed_at < DATE '2025-10-01'
  GROUP BY t40.tenant_id
)
SELECT
  t0.name AS merchant_name,
  t0.industry AS vertical,
  {{divide_decimal(100.0 * COALESCE(t3.refund_eur_q4, 0), NULLIF(t1.captured_eur_q4, 0))}} AS refund_rate_q4_pct,
  {{divide_decimal(100.0 * COALESCE(t4.refund_eur_baseline, 0), NULLIF(t2.captured_eur_baseline, 0))}} AS refund_rate_baseline_pct,
  ({{divide_decimal(100.0 * COALESCE(t3.refund_eur_q4, 0), NULLIF(t1.captured_eur_q4, 0))}})
  - ({{divide_decimal(100.0 * COALESCE(t4.refund_eur_baseline, 0), NULLIF(t2.captured_eur_baseline, 0))}}) AS change_vs_baseline_pp,
  COALESCE(t3.refund_eur_q4, 0) AS refund_amount_q4_eur,
  t1.order_count_q4 AS order_count_q4
FROM tenants AS t0
JOIN t1 ON t1.tenant_id = t0.id
LEFT JOIN t2 ON t2.tenant_id = t0.id
LEFT JOIN t3 ON t3.tenant_id = t0.id
LEFT JOIN t4 ON t4.tenant_id = t0.id
WHERE t1.order_count_q4 >= 10
ORDER BY change_vs_baseline_pp DESC NULLS LAST, refund_amount_q4_eur DESC NULLS FIRST, t0.id ASC NULLS LAST
