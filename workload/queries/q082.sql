WITH target_tenants AS (
  SELECT id FROM tenants
  WHERE name IN ('Kibblewick','Studio Vrij','Petalcourt Beauty','Marrowby & Vane','Cragsley Outfitters','Ampfeld Elektronik')
),
base_orders AS (
  SELECT o.id AS id, o.created_at AS created_at
  FROM orders o
  JOIN target_tenants t ON t.id = o.tenant_id
  WHERE o.created_at >= TIMESTAMP '2025-10-01' AND o.created_at < TIMESTAMP '2026-01-01'
),
total AS (
  SELECT count(*) AS total_orders FROM base_orders
),
statuses AS (
  SELECT status FROM (VALUES ('pending'), ('confirmed'), ('paid'), ('partially_fulfilled'), ('fulfilled'), ('cancelled'), ('refunded')) AS s(status)
),
first_reach AS (
  SELECT bo.id AS order_id, osh.to_status AS status, min(osh.created_at) AS first_at
  FROM base_orders bo
  JOIN order_status_history osh ON osh.order_id = bo.id
  WHERE osh.to_status IN ('pending','confirmed','paid','partially_fulfilled','fulfilled','cancelled','refunded')
  GROUP BY bo.id, osh.to_status
),
joined AS (
  SELECT fr.order_id AS order_id, fr.status AS status, fr.first_at AS first_at, bo.created_at AS created_at,
         {{divide_decimal({{seconds_between(bo.created_at, fr.first_at)}}, 3600.0)}} AS hours
  FROM first_reach fr
  JOIN base_orders bo ON bo.id = fr.order_id
)
SELECT
  s.status AS status,
  count(j.order_id) AS orders_reaching_status,
  {{divide_decimal(100.0 * count(j.order_id), NULLIF(t.total_orders, 0))}} AS pct_of_total_orders,
  {{percentile_cont(0.5, j.hours)}} AS median_hours_from_order_creation
FROM statuses s
CROSS JOIN total t
LEFT JOIN joined j ON j.status = s.status
GROUP BY s.status, t.total_orders
ORDER BY pct_of_total_orders DESC NULLS FIRST, s.status ASC NULLS LAST
