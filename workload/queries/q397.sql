SELECT t.industry AS industry,
  COUNT(*) AS total_routine_adjustments_2025,
  COUNT(DISTINCT sa.variant_id) AS distinct_variants_with_adjustment,
  {{divide_decimal(CAST(COUNT(*) AS numeric(18,6)), NULLIF(COUNT(DISTINCT sa.variant_id), 0))}} AS adjustments_per_variant,
  COUNT(DISTINCT t.id) AS distinct_tenants_in_industry
FROM stock_adjustments sa
JOIN stock_locations sl ON sl.id = sa.stock_location_id
JOIN warehouses w ON w.id = sl.warehouse_id
JOIN tenants t ON t.id = w.tenant_id
WHERE sa.created_at >= DATE '2025-01-01' AND sa.created_at < DATE '2026-01-01'
GROUP BY t.industry
ORDER BY adjustments_per_variant DESC NULLS FIRST, t.industry ASC NULLS LAST
