WITH paid_orders AS (
  SELECT tenant_id, COUNT(*) AS paid_order_count
  FROM orders
  WHERE placed_at >= DATE '2025-10-01' AND placed_at < DATE '2026-01-01'
    AND status NOT IN ('pending', 'cancelled')
  GROUP BY tenant_id
),
top_tenants AS (
  SELECT tenant_id, paid_order_count
  FROM paid_orders
  ORDER BY paid_order_count DESC NULLS FIRST, tenant_id ASC NULLS LAST
  {{fetch_first(10)}}
),
visits AS (
  SELECT tenant_id, COUNT(*) AS visit_count
  FROM web_sessions
  WHERE started_at >= DATE '2025-10-01' AND started_at < DATE '2026-01-01'
  GROUP BY tenant_id
),
carts_created AS (
  SELECT tenant_id, COUNT(*) AS cart_count
  FROM carts
  WHERE created_at >= DATE '2025-10-01' AND created_at < DATE '2026-01-01'
  GROUP BY tenant_id
),
orders_placed AS (
  SELECT tenant_id, COUNT(*) AS order_count
  FROM orders
  WHERE placed_at >= DATE '2025-10-01' AND placed_at < DATE '2026-01-01'
  GROUP BY tenant_id
),
assembled AS (
  SELECT
    t.id AS tenant_id,
    t.name AS tenant_name,
    COALESCE(v.visit_count, 0) AS visits,
    COALESCE(c.cart_count, 0) AS carts_created,
    COALESCE(o.order_count, 0) AS orders_placed,
    tt.paid_order_count AS orders_paid
  FROM top_tenants tt
  JOIN tenants t ON t.id = tt.tenant_id
  LEFT JOIN visits v ON v.tenant_id = tt.tenant_id
  LEFT JOIN carts_created c ON c.tenant_id = tt.tenant_id
  LEFT JOIN orders_placed o ON o.tenant_id = tt.tenant_id
)
SELECT
  tenant_name,
  visits,
  carts_created,
  orders_placed,
  orders_paid,
  CASE WHEN visits > 0 THEN {{divide_decimal(100.0 * carts_created, visits)}} ELSE NULL END AS visit_to_cart_pct,
  CASE WHEN carts_created > 0 THEN {{divide_decimal(100.0 * orders_placed, carts_created)}} ELSE NULL END AS cart_to_order_pct,
  CASE WHEN orders_placed > 0 THEN {{divide_decimal(100.0 * orders_paid, orders_placed)}} ELSE NULL END AS order_to_paid_pct,
  CASE WHEN visits > 0 THEN {{divide_decimal(100.0 * orders_paid, visits)}} ELSE NULL END AS overall_visit_to_paid_pct
FROM assembled
ORDER BY overall_visit_to_paid_pct DESC NULLS LAST, tenant_name ASC NULLS LAST, tenant_id NULLS LAST
