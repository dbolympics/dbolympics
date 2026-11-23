WITH target_tenants AS (
  SELECT id, name FROM tenants
  WHERE name IN ('Brennquell Kaffee','Spice Route Box','Grind Collective','Honeycomb Larder','Kibblewick','Studio Vrij','Petalcourt Beauty','Marrowby & Vane','Cragsley Outfitters','Ampfeld Elektronik')
),
shipment_stats AS (
  SELECT o.tenant_id AS tenant_id,
    COUNT(*) AS shipments_delivered,
    {{percentile_cont(0.5, {{divide_decimal({{seconds_between(s.shipped_at, s.delivered_at)}}, 86400.0)}})}} AS median_delivery_days,
    AVG(CASE WHEN {{divide_decimal({{seconds_between(s.shipped_at, s.delivered_at)}}, 86400.0)}} > 7 THEN 100.0 ELSE 0.0 END) AS pct_over_7
  FROM shipments s
  JOIN fulfillments f ON f.id = s.fulfillment_id
  JOIN orders o ON o.id = f.order_id
  WHERE s.shipped_at >= DATE '2025-10-01' AND s.shipped_at < DATE '2026-01-01'
    AND s.delivered_at IS NOT NULL
    AND o.tenant_id IN (SELECT id FROM target_tenants)
  GROUP BY o.tenant_id
),
order_stats AS (
  SELECT o.tenant_id AS tenant_id,
    COUNT(*) AS q4_orders,
    COUNT(*) FILTER (WHERE EXISTS (SELECT 1 FROM order_returns r WHERE r.order_id = o.id)) AS orders_with_return
  FROM orders o
  WHERE o.placed_at >= DATE '2025-10-01' AND o.placed_at < DATE '2026-01-01'
    AND o.tenant_id IN (SELECT id FROM target_tenants)
  GROUP BY o.tenant_id
)
SELECT t.name AS tenant_name,
  COALESCE(ss.shipments_delivered,0) AS shipments_delivered,
  ss.median_delivery_days AS median_delivery_days,
  ss.pct_over_7 AS pct_over_7_days,
  ({{divide_decimal(CAST(os.orders_with_return AS numeric(18,6)), NULLIF(os.q4_orders,0))}}) * 100 AS pct_orders_with_return
FROM target_tenants t
LEFT JOIN shipment_stats ss ON ss.tenant_id = t.id
LEFT JOIN order_stats os ON os.tenant_id = t.id
ORDER BY pct_over_7_days DESC NULLS LAST, t.name ASC NULLS LAST, t.id ASC NULLS LAST
