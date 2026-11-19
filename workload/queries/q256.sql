WITH t0 AS (
  SELECT
    o.id AS order_id,
    t.industry AS industry,
    CASE WHEN o.discount_total > 0 THEN 'discounted' ELSE 'full price' END AS order_group,
    CAST({{divide_decimal(o.subtotal, er.rate)}} AS NUMERIC(18,6)) AS subtotal_eur,
    CAST({{divide_decimal(o.discount_total, er.rate)}} AS NUMERIC(18,6)) AS discount_eur
  FROM orders o
  JOIN tenants t ON t.id = o.tenant_id
  JOIN exchange_rates er
    ON er.base_code = 'EUR'
   AND er.quote_code = o.currency_code
   AND er.as_of = CAST(o.placed_at AS date)
  WHERE o.placed_at >= TIMESTAMP '2025-01-01'
    AND o.placed_at < TIMESTAMP '2026-01-01'
),
t1 AS (
  SELECT
    orr.order_id AS order_id,
    SUM(CAST({{divide_decimal(orr.refund_total, er2.rate)}} AS NUMERIC(18,6))) AS refund_eur
  FROM order_returns orr
  JOIN exchange_rates er2
    ON er2.base_code = 'EUR'
   AND er2.quote_code = orr.currency_code
   AND er2.as_of = CAST(COALESCE(orr.refunded_at, orr.requested_at) AS date)
  GROUP BY orr.order_id
),
t2 AS (
  SELECT DISTINCT industry, order_group FROM t0
),
t3 AS (
  SELECT industry, order_group,
    COUNT(*) AS orders_count,
    SUM(discount_eur) AS discount_given_eur_raw,
    SUM(subtotal_eur) AS gmv_eur_raw
  FROM t0
  GROUP BY industry, order_group
),
t4 AS (
  SELECT t0.industry AS industry, t0.order_group AS order_group,
    SUM(COALESCE(t1.refund_eur,0)) AS refund_amount_eur_raw
  FROM t0
  LEFT JOIN t1 ON t1.order_id = t0.order_id
  GROUP BY t0.industry, t0.order_group
),
t5 AS (
  SELECT t0.industry AS industry, t0.order_group AS order_group,
    COUNT(DISTINCT CASE WHEN t1.order_id IS NOT NULL THEN t0.order_id END) AS orders_with_return
  FROM t0
  LEFT JOIN t1 ON t1.order_id = t0.order_id
  GROUP BY t0.industry, t0.order_group
)
SELECT
  t2.industry AS industry,
  t2.order_group AS order_group,
  COALESCE(t3.orders_count, 0) AS orders_count,
  COALESCE(t3.discount_given_eur_raw,0) AS discount_given_eur,
  COALESCE(t4.refund_amount_eur_raw,0) AS refund_amount_eur,
  COALESCE(t3.gmv_eur_raw,0) AS gmv_eur,
  CASE WHEN COALESCE(t3.gmv_eur_raw,0) = 0 THEN NULL
  ELSE {{divide_decimal((COALESCE(t3.discount_given_eur_raw,0) + COALESCE(t4.refund_amount_eur_raw,0)), t3.gmv_eur_raw)}} * 100 END AS net_leakage_pct,
  CASE WHEN COALESCE(t3.orders_count,0) = 0 THEN NULL
  ELSE {{divide_decimal(CAST(COALESCE(t5.orders_with_return,0) AS numeric(18,6)), t3.orders_count)}} * 100 END AS refund_rate_pct
FROM t2
LEFT JOIN t3 ON t3.industry = t2.industry AND t3.order_group = t2.order_group
LEFT JOIN t4 ON t4.industry = t2.industry AND t4.order_group = t2.order_group
LEFT JOIN t5 ON t5.industry = t2.industry AND t5.order_group = t2.order_group
ORDER BY t2.industry ASC NULLS LAST, t2.order_group ASC NULLS LAST
