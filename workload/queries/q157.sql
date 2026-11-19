WITH orphan_orders AS (
  SELECT
    o.id AS order_id,
    o.tenant_id AS tenant_id,
    o.user_id AS user_id,
    o.placed_at AS placed_at,
    od.amount AS discount_amount,
    od.currency_code AS discount_currency
  FROM orders o
  JOIN order_discounts od
    ON od.order_id = o.id
   AND od.tenant_id = o.tenant_id
  JOIN discounts d
    ON d.id = od.discount_id
   AND d.tenant_id = o.tenant_id
  WHERE d.name = 'Subscription delivery (prepaid)'
    AND o.placed_at >= DATE '2025-01-01'
    AND o.placed_at < DATE '2026-01-01'
    AND o.status <> 'cancelled'
    AND NOT EXISTS (
      SELECT 1
      FROM subscriptions s
      WHERE s.tenant_id = o.tenant_id
        AND s.user_id = o.user_id
        AND s.status IN ('trialing','active','past_due')
        AND s.started_at <= o.placed_at
        AND (s.ended_at IS NULL OR s.ended_at >= o.placed_at)
    )
),
latest_subscription AS (
  SELECT
    s.tenant_id AS tenant_id,
    s.user_id AS user_id,
    s.status AS status,
    s.ended_at AS ended_at,
    s.started_at AS started_at,
    ROW_NUMBER() OVER (PARTITION BY s.tenant_id, s.user_id ORDER BY s.started_at DESC NULLS FIRST, s.id DESC NULLS FIRST) AS rn
  FROM subscriptions s
),
orphan_with_category AS (
  SELECT
    oo.order_id AS order_id,
    oo.tenant_id AS tenant_id,
    oo.user_id AS user_id,
    oo.placed_at AS placed_at,
    oo.discount_amount AS discount_amount,
    oo.discount_currency AS discount_currency,
    COALESCE(ls.status, 'no_subscription_record') AS status_category,
    ls.ended_at AS sub_ended_at
  FROM orphan_orders oo
  LEFT JOIN latest_subscription ls
    ON ls.tenant_id = oo.tenant_id
   AND ls.user_id = oo.user_id
   AND ls.rn = 1
),
t0 AS (
  SELECT DISTINCT status_category FROM orphan_with_category
),
t1 AS (
  SELECT status_category, COUNT(*) AS orphan_customer_count
  FROM (
    SELECT DISTINCT status_category, tenant_id, user_id
    FROM orphan_with_category
  ) dc
  GROUP BY status_category
),
t2 AS (
  SELECT status_category, COUNT(*) AS orphan_order_count
  FROM orphan_with_category
  GROUP BY status_category
),
t3 AS (
  SELECT COUNT(*) AS total_orphan_orders FROM orphan_with_category
),
t4 AS (
  SELECT status_category,
         AVG(CAST(COALESCE(CAST(sub_ended_at AS date), DATE '2026-01-05') - CAST(placed_at AS date) AS NUMERIC(18,6))) AS avg_days_sub_end_to_order
  FROM orphan_with_category
  WHERE status_category <> 'no_subscription_record'
  GROUP BY status_category
),
t5 AS (
  SELECT ow.status_category AS status_category,
         SUM(
           CASE WHEN ow.discount_currency = 'EUR' THEN CAST(ow.discount_amount AS NUMERIC(18,6))
                ELSE CAST({{divide_decimal(ow.discount_amount, er.rate)}} AS NUMERIC(18,6))
           END
         ) AS total_discount_eur
  FROM orphan_with_category ow
  LEFT JOIN exchange_rates er
    ON er.base_code = 'EUR'
   AND er.quote_code = ow.discount_currency
   AND er.as_of = CAST(ow.placed_at AS date)
  GROUP BY ow.status_category
)
SELECT
  t0.status_category AS status_category,
  COALESCE(t1.orphan_customer_count, 0) AS orphan_customer_count,
  COALESCE(t2.orphan_order_count, 0) AS orphan_order_count,
  {{divide_decimal(100.0 * COALESCE(t2.orphan_order_count, 0), NULLIF(t3.total_orphan_orders, 0))}} AS pct_of_all_orphan_orders,
  t4.avg_days_sub_end_to_order AS avg_days_sub_end_to_order,
  COALESCE(t5.total_discount_eur, 0) AS total_discount_amount_eur
FROM t0
LEFT JOIN t1 ON t1.status_category = t0.status_category
LEFT JOIN t2 ON t2.status_category = t0.status_category
CROSS JOIN t3
LEFT JOIN t4 ON t4.status_category = t0.status_category
LEFT JOIN t5 ON t5.status_category = t0.status_category
ORDER BY COALESCE(t2.orphan_order_count, 0) DESC NULLS FIRST, t0.status_category ASC NULLS LAST
