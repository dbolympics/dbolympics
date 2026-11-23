SELECT
  t0.id AS tenant_id,
  t0.name AS merchant_name,
  t0.industry AS industry,
  t1.distinct_customers AS distinct_customers,
  COALESCE(t2.repeat_customers, 0) AS repeat_customers,
  {{divide_decimal(COALESCE(t2.repeat_customers, 0) * 100.0, t1.distinct_customers)}} AS repeat_purchase_rate_pct,
  COALESCE(t3.total_orders, 0) AS total_orders_last_12_months,
  {{divide_decimal(COALESCE(t3.total_orders, 0) * 1.0, t1.distinct_customers)}} AS avg_orders_per_customer
FROM tenants t0
INNER JOIN (
  SELECT o.tenant_id AS tenant_id, COUNT(DISTINCT o.user_id) AS distinct_customers
  FROM orders o
  WHERE o.placed_at >= DATE '2025-01-01' AND o.placed_at < DATE '2026-01-01'
    AND o.status <> 'cancelled'
  GROUP BY o.tenant_id
) t1 ON t1.tenant_id = t0.id
LEFT JOIN (
  SELECT x.tenant_id AS tenant_id, COUNT(*) AS repeat_customers
  FROM (
    SELECT o.tenant_id AS tenant_id, o.user_id AS user_id, COUNT(*) AS order_count
    FROM orders o
    WHERE o.placed_at >= DATE '2025-01-01' AND o.placed_at < DATE '2026-01-01'
      AND o.status <> 'cancelled'
    GROUP BY o.tenant_id, o.user_id
  ) x
  WHERE x.order_count >= 2
  GROUP BY x.tenant_id
) t2 ON t2.tenant_id = t0.id
LEFT JOIN (
  SELECT o.tenant_id AS tenant_id, COUNT(*) AS total_orders
  FROM orders o
  WHERE o.placed_at >= DATE '2025-01-01' AND o.placed_at < DATE '2026-01-01'
    AND o.status <> 'cancelled'
  GROUP BY o.tenant_id
) t3 ON t3.tenant_id = t0.id
ORDER BY distinct_customers DESC NULLS FIRST, repeat_purchase_rate_pct DESC NULLS FIRST, t0.id ASC NULLS LAST
{{fetch_first(50)}}
