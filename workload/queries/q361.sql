WITH t0 AS (
  SELECT d.id AS discount_id, d.tenant_id AS tenant_id
  FROM discounts d
  WHERE d.name = 'Welcome 10% off'
),
t1 AS (
  SELECT
    t0.discount_id AS discount_id,
    COUNT(DISTINCT o.id) AS order_count_2025
  FROM t0
  JOIN order_discounts od ON od.discount_id = t0.discount_id
  JOIN orders o ON o.id = od.order_id
  WHERE o.status <> 'cancelled'
    AND o.placed_at >= DATE '2025-01-01'
    AND o.placed_at < DATE '2026-01-01'
  GROUP BY t0.discount_id
),
t2 AS (
  SELECT t1.discount_id AS discount_id
  FROM t1
  WHERE t1.order_count_2025 = 260
),
t3 AS (
  SELECT DISTINCT o.id AS order_id, o.placed_at AS order_placed_at
  FROM order_discounts od
  JOIN t2 ON t2.discount_id = od.discount_id
  JOIN orders o ON o.id = od.order_id
  WHERE o.status <> 'cancelled'
    AND o.placed_at >= DATE '2025-01-01'
    AND o.placed_at < DATE '2026-01-01'
),
t4 AS (
  SELECT
    oi.id AS order_item_id,
    oi.order_id AS order_id,
    t3.order_placed_at AS order_placed_at,
    COALESCE(cat.id, -1) AS category_id,
    COALESCE(cat.name, 'Uncategorized') AS category_name
  FROM order_items oi
  JOIN t3 ON t3.order_id = oi.order_id
  JOIN product_variants pv ON pv.id = oi.product_variant_id
  JOIN products p ON p.id = pv.product_id
  LEFT JOIN categories cat ON cat.id = p.primary_category_id
),
t5 AS (
  SELECT DISTINCT t4.category_id AS category_id, t4.category_name AS category_name
  FROM t4
),
t6 AS (
  SELECT
    ri.id AS return_item_id,
    ri.order_item_id AS order_item_id,
    ri.refund_amount AS refund_amount,
    ri.currency_code AS currency_code,
    ret.requested_at AS requested_at,
    ret.refunded_at AS refunded_at
  FROM return_items ri
  JOIN order_returns ret ON ret.id = ri.return_id
  JOIN t4 ON t4.order_item_id = ri.order_item_id
),
t7 AS (
  SELECT
    t6.return_item_id AS return_item_id,
    t6.order_item_id AS order_item_id,
    t6.refund_amount AS refund_amount,
    t6.requested_at AS requested_at,
    er.rate AS eur_rate
  FROM t6
  LEFT JOIN exchange_rates er
    ON er.base_code = 'EUR'
   AND er.quote_code = t6.currency_code
   AND er.as_of = CAST(COALESCE(t6.requested_at, t6.refunded_at) AS date)
),
t8 AS (
  SELECT
    t4.category_id AS category_id,
    t7.return_item_id AS return_item_id,
    CAST({{divide_decimal(t7.refund_amount, NULLIF(t7.eur_rate, 0))}} AS NUMERIC(18,6)) AS refund_amount_eur,
    {{date_diff_days(t4.order_placed_at, t7.requested_at)}} AS days_to_return
  FROM t7
  JOIN t4 ON t4.order_item_id = t7.order_item_id
),
t9 AS (
  SELECT
    t4.category_id AS category_id,
    COUNT(*) AS items_sold,
    COUNT(DISTINCT t4.order_id) AS distinct_orders
  FROM t4
  GROUP BY t4.category_id
),
t10 AS (
  SELECT
    t8.category_id AS category_id,
    COUNT(*) AS items_returned,
    SUM(t8.refund_amount_eur) AS total_refund_eur,
    AVG(CAST(t8.days_to_return AS NUMERIC(18,6))) AS avg_days_to_return
  FROM t8
  GROUP BY t8.category_id
),
t11 AS (
  SELECT SUM(t8.refund_amount_eur) AS grand_total_refund_eur
  FROM t8
)
SELECT
  t5.category_name AS category_name,
  COALESCE(t9.items_sold, 0) AS order_items_sold,
  COALESCE(t9.distinct_orders, 0) AS distinct_orders,
  COALESCE(t10.items_returned, 0) AS items_returned,
  {{divide_decimal(100.0 * COALESCE(t10.items_returned, 0), NULLIF(COALESCE(t9.items_sold, 0), 0))}} AS return_rate_pct,
  COALESCE(t10.total_refund_eur, 0) AS total_refund_eur,
  {{divide_decimal(100.0 * COALESCE(t10.total_refund_eur, 0), NULLIF(t11.grand_total_refund_eur, 0))}} AS share_of_instance_refund_pct,
  t10.avg_days_to_return AS avg_days_order_to_return
FROM t5
LEFT JOIN t9 ON t9.category_id = t5.category_id
LEFT JOIN t10 ON t10.category_id = t5.category_id
CROSS JOIN t11
ORDER BY total_refund_eur DESC NULLS FIRST, category_name ASC NULLS LAST, t5.category_id NULLS LAST
