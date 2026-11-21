WITH promo_names AS (
  SELECT name FROM (VALUES
    ('Welcome 10% off'),
    ('Black Friday 2025'),
    ('January Sale 2025'),
    ('Summer Sale 2025')
  ) AS v(name)
),
discounted AS (
  SELECT d.name AS promo_name,
         d.id AS discount_id,
         o.tenant_id AS tenant_id,
         o.user_id AS user_id,
         o.id AS order_id,
         CAST({{divide_decimal(o.subtotal, er.rate)}} AS NUMERIC(18,6)) AS subtotal_eur
  FROM order_discounts od
  JOIN discounts d ON d.id = od.discount_id AND d.tenant_id = od.tenant_id
  JOIN orders o ON o.id = od.order_id AND o.tenant_id = od.tenant_id
  JOIN exchange_rates er ON er.base_code = 'EUR' AND er.quote_code = o.currency_code AND er.as_of = CAST(o.placed_at AS DATE)
  WHERE d.name IN (SELECT name FROM promo_names)
    AND o.placed_at >= DATE '2025-01-01'
    AND o.placed_at < DATE '2026-01-01'
    AND o.status <> 'cancelled'
),
discounted_orders AS (
  SELECT promo_name, tenant_id, user_id, order_id, MAX(subtotal_eur) AS subtotal_eur
  FROM discounted
  GROUP BY promo_name, tenant_id, user_id, order_id
),
instance_customers AS (
  SELECT promo_name, discount_id, COUNT(DISTINCT tenant_id || ':' || user_id) AS customers_in_instance
  FROM discounted
  GROUP BY promo_name, discount_id
),
discounted_agg AS (
  SELECT promo_name,
         COUNT(*) AS discounted_order_count,
         SUM(subtotal_eur) AS discounted_subtotal_sum
  FROM discounted_orders
  GROUP BY promo_name
),
instance_agg AS (
  SELECT promo_name,
         COUNT(DISTINCT discount_id) AS discount_instances,
         SUM(customers_in_instance) AS distinct_customers_summed
  FROM instance_customers
  GROUP BY promo_name
),
customer_set AS (
  SELECT DISTINCT promo_name, tenant_id, user_id FROM discounted_orders
),
customer_set_agg AS (
  SELECT promo_name, COUNT(*) AS customer_set_count FROM customer_set GROUP BY promo_name
),
comparison_orders AS (
  SELECT cs.promo_name AS promo_name, cs.tenant_id AS tenant_id, cs.user_id AS user_id, o.id AS order_id,
         CAST({{divide_decimal(o.subtotal, er.rate)}} AS NUMERIC(18,6)) AS subtotal_eur
  FROM customer_set cs
  JOIN orders o ON o.tenant_id = cs.tenant_id AND o.user_id = cs.user_id
  JOIN exchange_rates er ON er.base_code = 'EUR' AND er.quote_code = o.currency_code AND er.as_of = CAST(o.placed_at AS DATE)
  WHERE o.placed_at >= DATE '2025-01-01'
    AND o.placed_at < DATE '2026-01-01'
    AND o.status <> 'cancelled'
    AND NOT EXISTS (
      SELECT 1 FROM order_discounts od2
      WHERE od2.tenant_id = o.tenant_id AND od2.order_id = o.id
    )
),
comparison_agg AS (
  SELECT promo_name,
         COUNT(*) AS comparison_order_count,
         SUM(subtotal_eur) AS comparison_subtotal_sum,
         COUNT(DISTINCT tenant_id || ':' || user_id) AS customers_with_comparison
  FROM comparison_orders
  GROUP BY promo_name
)
SELECT
  pn.name AS promotion_name,
  COALESCE(ia.discount_instances, 0) AS discount_instances,
  COALESCE(da.discounted_order_count, 0) AS discounted_order_count,
  COALESCE(ia.distinct_customers_summed, 0) AS distinct_customers,
  {{divide_decimal(da.discounted_subtotal_sum, NULLIF(da.discounted_order_count,0))}} AS avg_discounted_order_subtotal_eur,
  {{divide_decimal(ca.comparison_subtotal_sum, NULLIF(ca.comparison_order_count,0))}} AS avg_comparison_order_subtotal_eur,
  ({{divide_decimal(da.discounted_subtotal_sum, NULLIF(da.discounted_order_count,0))}})
  - ({{divide_decimal(ca.comparison_subtotal_sum, NULLIF(ca.comparison_order_count,0))}}) AS subtotal_lift_eur,
  100.0 * (
    ({{divide_decimal(da.discounted_subtotal_sum, NULLIF(da.discounted_order_count,0))}})
    - ({{divide_decimal(ca.comparison_subtotal_sum, NULLIF(ca.comparison_order_count,0))}})
  ) / NULLIF({{divide_decimal(ca.comparison_subtotal_sum, NULLIF(ca.comparison_order_count,0))}}, 0) AS subtotal_lift_pct,
  {{divide_decimal(100.0 * COALESCE(ca.customers_with_comparison,0), NULLIF(cs.customer_set_count,0))}} AS pct_customers_with_comparison_order
FROM promo_names pn
LEFT JOIN instance_agg ia ON ia.promo_name = pn.name
LEFT JOIN discounted_agg da ON da.promo_name = pn.name
LEFT JOIN customer_set_agg cs ON cs.promo_name = pn.name
LEFT JOIN comparison_agg ca ON ca.promo_name = pn.name
ORDER BY subtotal_lift_pct ASC NULLS LAST, pn.name NULLS LAST
