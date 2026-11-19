WITH order_base AS (
  SELECT
    o.id AS order_id,
    o.grand_total AS grand_total,
    o.currency_code AS currency_code,
    o.placed_at AS placed_at,
    (DATE '2025-12-31' - CAST(o.placed_at AS date)) AS age_days,
    CASE
      WHEN (DATE '2025-12-31' - CAST(o.placed_at AS date)) <= 3 THEN '0-3 days'
      WHEN (DATE '2025-12-31' - CAST(o.placed_at AS date)) <= 7 THEN '4-7 days'
      WHEN (DATE '2025-12-31' - CAST(o.placed_at AS date)) <= 14 THEN '8-14 days'
      WHEN (DATE '2025-12-31' - CAST(o.placed_at AS date)) <= 30 THEN '15-30 days'
      WHEN (DATE '2025-12-31' - CAST(o.placed_at AS date)) <= 60 THEN '31-60 days'
      WHEN (DATE '2025-12-31' - CAST(o.placed_at AS date)) <= 90 THEN '61-90 days'
      WHEN (DATE '2025-12-31' - CAST(o.placed_at AS date)) <= 180 THEN '91-180 days'
      WHEN (DATE '2025-12-31' - CAST(o.placed_at AS date)) <= 365 THEN '181-365 days'
      ELSE '366+ days'
    END AS age_bucket
  FROM orders o
  WHERE o.status <> 'cancelled'
    AND o.placed_at >= TIMESTAMP '2023-01-01'
    AND o.placed_at < TIMESTAMP '2026-01-01'
),
order_count_agg AS (
  SELECT t0.age_bucket AS age_bucket, COUNT(*) AS order_count
  FROM order_base t0
  GROUP BY t0.age_bucket
),
grand_total_agg AS (
  SELECT t1.age_bucket AS age_bucket, SUM(CAST({{divide_decimal(t1.grand_total, t2.rate)}} AS NUMERIC(18,6))) AS orders_grand_total_eur
  FROM order_base t1
  JOIN exchange_rates t2
    ON t2.base_code = 'EUR'
    AND t2.quote_code = t1.currency_code
    AND t2.as_of = CAST(t1.placed_at AS date)
  GROUP BY t1.age_bucket
),
payment_agg AS (
  SELECT t3.age_bucket AS age_bucket, SUM(CAST({{divide_decimal(t4.amount, t5.rate)}} AS NUMERIC(18,6))) AS matched_money_collected_eur
  FROM order_base t3
  JOIN payments t4
    ON t4.order_id = t3.order_id
    AND t4.status IN ('captured', 'refunded', 'partially_refunded')
  JOIN exchange_rates t5
    ON t5.base_code = 'EUR'
    AND t5.quote_code = t4.currency_code
    AND t5.as_of = CAST(t4.captured_at AS date)
  GROUP BY t3.age_bucket
)
SELECT
  t6.age_bucket AS age_bucket,
  t6.order_count AS order_count,
  COALESCE(t7.orders_grand_total_eur, 0) AS orders_grand_total_eur,
  COALESCE(t8.matched_money_collected_eur, 0) AS matched_money_collected_eur,
  {{divide_decimal(COALESCE(t8.matched_money_collected_eur, 0), NULLIF(t7.orders_grand_total_eur, 0))}} * 100 AS match_rate_pct
FROM order_count_agg t6
LEFT JOIN grand_total_agg t7 ON t7.age_bucket = t6.age_bucket
LEFT JOIN payment_agg t8 ON t8.age_bucket = t6.age_bucket
ORDER BY
  CASE t6.age_bucket
    WHEN '0-3 days' THEN 1
    WHEN '4-7 days' THEN 2
    WHEN '8-14 days' THEN 3
    WHEN '15-30 days' THEN 4
    WHEN '31-60 days' THEN 5
    WHEN '61-90 days' THEN 6
    WHEN '91-180 days' THEN 7
    WHEN '181-365 days' THEN 8
    ELSE 9
  END NULLS LAST
