SELECT
  t0.name AS tenant_name,
  t0.industry AS industry,
  COALESCE(t1.orders_jan_jul, 0) AS orders_jan_jul_2025,
  {{divide_decimal(COALESCE(t1.discount_orders, 0) * 100.0, NULLIF(t1.orders_jan_jul, 0))}} AS discount_rate_jan_jul_pct,
  COALESCE(t2.orders_other, 0) AS orders_other_months_2025,
  {{divide_decimal(COALESCE(t2.discount_orders, 0) * 100.0, NULLIF(t2.orders_other, 0))}} AS discount_rate_other_months_pct,
  ({{divide_decimal(COALESCE(t1.discount_orders, 0) * 100.0, NULLIF(t1.orders_jan_jul, 0))}})
    - ({{divide_decimal(COALESCE(t2.discount_orders, 0) * 100.0, NULLIF(t2.orders_other, 0))}}) AS delta_pct_points
FROM tenants t0
JOIN (
  SELECT
    o1.tenant_id AS tenant_id,
    COUNT(*) AS orders_jan_jul,
    SUM(CASE WHEN o1.discount_total > 0 THEN 1 ELSE 0 END) AS discount_orders
  FROM orders o1
  WHERE o1.placed_at IS NOT NULL
    AND EXTRACT(YEAR FROM o1.placed_at) = 2025
    AND EXTRACT(MONTH FROM o1.placed_at) IN (1, 7)
  GROUP BY o1.tenant_id
) t1 ON t1.tenant_id = t0.id
LEFT JOIN (
  SELECT
    o2.tenant_id AS tenant_id,
    COUNT(*) AS orders_other,
    SUM(CASE WHEN o2.discount_total > 0 THEN 1 ELSE 0 END) AS discount_orders
  FROM orders o2
  WHERE o2.placed_at IS NOT NULL
    AND EXTRACT(YEAR FROM o2.placed_at) = 2025
    AND EXTRACT(MONTH FROM o2.placed_at) NOT IN (1, 7)
  GROUP BY o2.tenant_id
) t2 ON t2.tenant_id = t0.id
WHERE t1.orders_jan_jul >= 20
ORDER BY delta_pct_points DESC NULLS FIRST, orders_jan_jul_2025 DESC NULLS FIRST, t0.id NULLS LAST
{{fetch_first(15)}}
