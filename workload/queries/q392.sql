WITH loc AS (
  SELECT sl.id AS stock_location_id, w.tenant_id AS tenant_id, sl.kind AS kind
  FROM stock_locations sl
  JOIN warehouses w ON w.id = sl.warehouse_id
  JOIN tenants t ON t.id = w.tenant_id
  WHERE t.name IN ('Deskline Supplies', 'OfficeHub Nordic', 'Kontor24 Bürobedarf', 'Hanse Industriebedarf', 'Castell Fasteners', 'Midland Safety Wear', 'Ballycorran Industrial Supply', 'Polder Packaging')
),
loc_agg AS (
  SELECT tenant_id,
    count(*) AS total_stock_locations,
    count(*) FILTER (WHERE kind = 'bulk') AS bulk_count,
    count(*) FILTER (WHERE kind = 'pick') AS pick_count
  FROM loc
  GROUP BY tenant_id
),
adj AS (
  SELECT l.tenant_id AS tenant_id,
    count(*) AS routine_stock_adjustments_2025,
    count(DISTINCT sa.variant_id) AS distinct_variants_with_routine_adjustment
  FROM stock_adjustments sa
  JOIN loc l ON l.stock_location_id = sa.stock_location_id
  WHERE sa.created_at >= DATE '2025-01-01' AND sa.created_at < DATE '2026-01-01'
  GROUP BY l.tenant_id
),
dec31 AS (
  SELECT l.tenant_id AS tenant_id,
    sum(abs(sm.quantity)) AS dec31_correction_abs_units,
    count(DISTINCT sm.variant_id) AS dec31_correction_distinct_variants
  FROM stock_movements sm
  JOIN loc l ON l.stock_location_id = sm.stock_location_id
  WHERE sm.kind = 'adjustment' AND CAST(sm.occurred_at AS date) = DATE '2025-12-31'
  GROUP BY l.tenant_id
)
SELECT t.name AS tenant_name,
  la.total_stock_locations AS total_stock_locations,
  {{divide_decimal(100.0 * la.bulk_count, la.total_stock_locations)}} AS pct_locations_kind_bulk,
  {{divide_decimal(100.0 * la.pick_count, la.total_stock_locations)}} AS pct_locations_kind_pick,
  coalesce(adj.routine_stock_adjustments_2025, 0) AS routine_stock_adjustments_2025,
  coalesce(adj.distinct_variants_with_routine_adjustment, 0) AS distinct_variants_with_routine_adjustment,
  coalesce(dec31.dec31_correction_abs_units, 0) AS dec31_correction_abs_units,
  coalesce(dec31.dec31_correction_distinct_variants, 0) AS dec31_correction_distinct_variants
FROM tenants t
JOIN loc_agg la ON la.tenant_id = t.id
LEFT JOIN adj ON adj.tenant_id = t.id
LEFT JOIN dec31 ON dec31.tenant_id = t.id
WHERE t.name IN ('Deskline Supplies', 'OfficeHub Nordic', 'Kontor24 Bürobedarf', 'Hanse Industriebedarf', 'Castell Fasteners', 'Midland Safety Wear', 'Ballycorran Industrial Supply', 'Polder Packaging')
ORDER BY dec31_correction_abs_units DESC NULLS FIRST, tenant_name NULLS LAST, t.id NULLS LAST
