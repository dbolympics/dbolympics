WITH base_orders AS (
  SELECT o.id AS order_id, o.tenant_id AS tenant_id, o.created_at AS order_created_at
  FROM orders o
  JOIN (
    SELECT o2.tenant_id AS tenant_id, COUNT(*) AS order_count
    FROM orders o2
    WHERE o2.created_at >= DATE '2025-10-01' AND o2.created_at < DATE '2026-01-01'
    GROUP BY o2.tenant_id
    ORDER BY order_count DESC NULLS FIRST, o2.tenant_id NULLS LAST
    {{fetch_first(10)}}
  ) top_tenants ON top_tenants.tenant_id = o.tenant_id
  WHERE o.created_at >= DATE '2025-10-01' AND o.created_at < DATE '2026-01-01'
),
total_orders AS (
  SELECT COUNT(DISTINCT order_id) AS total_orders FROM base_orders
),
status_list AS (
  SELECT status_name FROM (VALUES ('pending'),('confirmed'),('paid'),('partially_fulfilled'),('fulfilled'),('cancelled'),('refunded')) AS s(status_name)
),
first_reach AS (
  SELECT bo.order_id AS order_id, osh.to_status AS status_name, MIN(osh.created_at) AS first_reached_at
  FROM base_orders bo
  JOIN order_status_history osh ON osh.order_id = bo.order_id
  WHERE osh.to_status IN ('pending','confirmed','paid','partially_fulfilled','fulfilled','cancelled','refunded')
  GROUP BY bo.order_id, osh.to_status
),
status_metrics AS (
  SELECT
    sl.status_name AS status_name,
    COUNT(DISTINCT fr.order_id) AS orders_reaching_status,
    {{percentile_cont(0.5, ({{divide_decimal({{seconds_between(bo.order_created_at, fr.first_reached_at)}}, 3600.0)}}))}} AS median_hours
  FROM status_list sl
  LEFT JOIN first_reach fr ON fr.status_name = sl.status_name
  LEFT JOIN base_orders bo ON bo.order_id = fr.order_id
  GROUP BY sl.status_name
)
SELECT
  sm.status_name AS status,
  COALESCE(sm.orders_reaching_status, 0) AS orders_reaching_status,
  {{divide_decimal(COALESCE(sm.orders_reaching_status, 0) * 100.0, NULLIF(t.total_orders, 0))}} AS pct_of_total_orders,
  sm.median_hours AS median_hours_to_status
FROM status_metrics sm
CROSS JOIN total_orders t
ORDER BY pct_of_total_orders DESC NULLS FIRST, sm.status_name ASC NULLS LAST
