SELECT
  t0.name AS tenant_name,
  COALESCE(t1.single_count, 0) AS single_item_cart_count,
  COALESCE(t2.single_conv_pct, 0) AS single_item_conversion_pct,
  COALESCE(t3.multi_count, 0) AS multi_item_cart_count,
  COALESCE(t4.multi_conv_pct, 0) AS multi_item_conversion_pct,
  COALESCE(t4.multi_conv_pct, 0) - COALESCE(t2.single_conv_pct, 0) AS gap_in_points
FROM tenants t0
LEFT JOIN (
  SELECT c0.tenant_id AS tenant_id, COUNT(*) AS single_count
  FROM carts c0
  WHERE c0.item_count = 1
    AND c0.created_at >= DATE '2025-01-01'
    AND c0.created_at < DATE '2026-01-01'
  GROUP BY c0.tenant_id
) t1 ON t1.tenant_id = t0.id
LEFT JOIN (
  SELECT c1.tenant_id AS tenant_id,
    {{divide_decimal(100.0 * SUM(CASE WHEN c1.status = 'converted' THEN 1 ELSE 0 END), COUNT(*))}} AS single_conv_pct
  FROM carts c1
  WHERE c1.item_count = 1
    AND c1.created_at >= DATE '2025-01-01'
    AND c1.created_at < DATE '2026-01-01'
  GROUP BY c1.tenant_id
) t2 ON t2.tenant_id = t0.id
LEFT JOIN (
  SELECT c2.tenant_id AS tenant_id, COUNT(*) AS multi_count
  FROM carts c2
  WHERE c2.item_count >= 2
    AND c2.created_at >= DATE '2025-01-01'
    AND c2.created_at < DATE '2026-01-01'
  GROUP BY c2.tenant_id
) t3 ON t3.tenant_id = t0.id
LEFT JOIN (
  SELECT c3.tenant_id AS tenant_id,
    {{divide_decimal(100.0 * SUM(CASE WHEN c3.status = 'converted' THEN 1 ELSE 0 END), COUNT(*))}} AS multi_conv_pct
  FROM carts c3
  WHERE c3.item_count >= 2
    AND c3.created_at >= DATE '2025-01-01'
    AND c3.created_at < DATE '2026-01-01'
  GROUP BY c3.tenant_id
) t4 ON t4.tenant_id = t0.id
WHERE t0.name IN ('Kibblewick', 'Studio Vrij', 'Petalcourt Beauty', 'Marrowby & Vane', 'Cragsley Outfitters', 'Ampfeld Elektronik')
ORDER BY gap_in_points DESC NULLS FIRST, tenant_name ASC NULLS LAST, t0.id ASC NULLS LAST
