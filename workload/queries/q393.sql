SELECT warehouse_name, tenant_name, distinct_pick_locations, total_routine_adjustments_2025,
  CASE WHEN distinct_pick_locations = 0 THEN NULL ELSE {{divide_decimal(CAST(total_routine_adjustments_2025 AS numeric(18,6)), distinct_pick_locations)}} END AS events_per_pick_location,
  distinct_variants_affected,
  avg_hour_of_day_of_entries
FROM (
  SELECT w.id as warehouse_id, w.name as warehouse_name, t.name as tenant_name,
    (SELECT COUNT(*) FROM stock_locations sl2 WHERE sl2.warehouse_id = w.id AND sl2.kind = 'pick') as distinct_pick_locations,
    (SELECT COUNT(*) FROM stock_adjustments sa2
       WHERE sa2.stock_location_id IN (SELECT sl3.id FROM stock_locations sl3 WHERE sl3.warehouse_id = w.id)
       AND sa2.created_at >= DATE '2025-01-01' AND sa2.created_at < DATE '2026-01-01') as total_routine_adjustments_2025,
    (SELECT COUNT(DISTINCT sa3.variant_id) FROM stock_adjustments sa3
       WHERE sa3.stock_location_id IN (SELECT sl4.id FROM stock_locations sl4 WHERE sl4.warehouse_id = w.id)
       AND sa3.created_at >= DATE '2025-01-01' AND sa3.created_at < DATE '2026-01-01') as distinct_variants_affected,
    (SELECT AVG(EXTRACT(HOUR FROM sa4.created_at)) FROM stock_adjustments sa4
       WHERE sa4.stock_location_id IN (SELECT sl5.id FROM stock_locations sl5 WHERE sl5.warehouse_id = w.id)
       AND sa4.created_at >= DATE '2025-01-01' AND sa4.created_at < DATE '2026-01-01') as avg_hour_of_day_of_entries
  FROM warehouses w
  JOIN tenants t ON w.tenant_id = t.id
  WHERE t.industry = 'Apparel & Footwear'
) sub
ORDER BY events_per_pick_location DESC NULLS LAST, total_routine_adjustments_2025 DESC NULLS FIRST, warehouse_name ASC NULLS LAST, warehouse_id ASC NULLS LAST
{{fetch_first(50)}}
