SELECT
  t.name AS tenant_name,
  t.industry AS industry,
  COALESCE(v.visits_2025, 0) AS visits_2025,
  COALESCE(o.orders_2025, 0) AS orders_2025,
  {{divide_decimal(CAST(COALESCE(v.visits_2025, 0) AS numeric(18,6)), NULLIF(COALESCE(o.orders_2025, 0), 0))}} AS visits_per_order,
  {{divide_decimal(100.0 * COALESCE(s.sub_linked_orders, 0), NULLIF(COALESCE(o.orders_2025, 0), 0))}} AS subscription_linked_orders_pct,
  COALESCE(a.active_subscriptions, 0) AS active_subscriptions
FROM tenants t
LEFT JOIN (
  SELECT tenant_id, COUNT(*) AS visits_2025
  FROM web_sessions
  WHERE started_at >= DATE '2025-01-01' AND started_at < DATE '2026-01-01'
  GROUP BY tenant_id
) v ON v.tenant_id = t.id
LEFT JOIN (
  SELECT tenant_id, COUNT(*) AS orders_2025
  FROM orders
  WHERE placed_at >= DATE '2025-01-01' AND placed_at < DATE '2026-01-01'
  GROUP BY tenant_id
) o ON o.tenant_id = t.id
LEFT JOIN (
  SELECT o2.tenant_id AS tenant_id, COUNT(*) AS sub_linked_orders
  FROM orders o2
  WHERE o2.placed_at >= DATE '2025-01-01' AND o2.placed_at < DATE '2026-01-01'
    AND EXISTS (
      SELECT 1 FROM invoices i
      WHERE i.order_id = o2.id AND i.subscription_id IS NOT NULL
    )
  GROUP BY o2.tenant_id
) s ON s.tenant_id = t.id
LEFT JOIN (
  SELECT tenant_id, COUNT(*) AS active_subscriptions
  FROM subscriptions
  WHERE status = 'active'
  GROUP BY tenant_id
) a ON a.tenant_id = t.id
WHERE t.name IN (
  'Brennquell Kaffee', 'Spice Route Box', 'Grind Collective', 'Honeycomb Larder',
  'Kibblewick', 'Studio Vrij', 'Petalcourt Beauty', 'Marrowby & Vane',
  'Cragsley Outfitters', 'Ampfeld Elektronik'
)
ORDER BY visits_per_order ASC NULLS LAST, tenant_name ASC NULLS LAST, t.id NULLS LAST
