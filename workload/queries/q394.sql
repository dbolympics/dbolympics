WITH three_warehouses AS (
  SELECT id, name FROM warehouses
  WHERE name IN ('Atlanta Fulfilment Centre','Reading Fulfilment Centre','Den Haag Fulfilment Centre')
),
adjustments AS (
  SELECT sa.variant_id AS variant_id, sa.reason AS reason, sa.created_at AS created_at, w.name AS warehouse_name
  FROM stock_adjustments sa
  JOIN stock_locations sl ON sl.id = sa.stock_location_id
  JOIN three_warehouses w ON w.id = sl.warehouse_id
  WHERE sa.created_at >= DATE '2025-01-01' AND sa.created_at < DATE '2026-01-01'
),
variant_info AS (
  SELECT pv.id AS variant_id, pv.sku AS sku, pv.name AS variant_name, p.name AS product_name
  FROM product_variants pv
  JOIN products p ON p.id = pv.product_id
),
aggregated AS (
  SELECT
    a.warehouse_name AS warehouse_name,
    vi.product_name AS product_name,
    vi.sku AS sku,
    vi.variant_name AS variant_name,
    COUNT(*) AS adjustment_count,
    {{divide_decimal(100.0 * SUM(CASE WHEN a.reason = 'Missing - suspected theft' THEN 1 ELSE 0 END), COUNT(*))}} AS pct_theft_reason,
    COUNT(DISTINCT CAST(a.created_at AS DATE)) AS distinct_days_affected
  FROM adjustments a
  JOIN variant_info vi ON vi.variant_id = a.variant_id
  GROUP BY a.warehouse_name, vi.product_name, vi.sku, vi.variant_name
)
SELECT
  warehouse_name,
  product_name,
  sku,
  variant_name,
  adjustment_count,
  pct_theft_reason,
  distinct_days_affected,
  COUNT(*) OVER () AS total_distinct_variants
FROM aggregated
ORDER BY adjustment_count DESC NULLS FIRST, warehouse_name ASC NULLS LAST, sku ASC NULLS LAST, product_name ASC NULLS LAST, variant_name ASC NULLS LAST
{{fetch_first(50)}}
