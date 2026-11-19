WITH t0 AS (
  SELECT
    t4.warehouse_id AS warehouse_id,
    t4.variant_id AS variant_id,
    SUM(t4.quantity) AS total_quantity,
    SUM(t4.reserved_quantity) AS total_reserved_quantity,
    SUM(t4.reorder_point) AS total_reorder_point
  FROM (
    SELECT
      si.variant_id AS variant_id,
      sl.warehouse_id AS warehouse_id,
      si.quantity AS quantity,
      si.reserved_quantity AS reserved_quantity,
      si.reorder_point AS reorder_point
    FROM stock_items si
    JOIN stock_locations sl ON sl.id = si.stock_location_id
  ) t4
  GROUP BY t4.warehouse_id, t4.variant_id
)
SELECT
  w0.name AS warehouse_name,
  t9.name AS tenant_name,
  t1.variants_tracked AS variants_tracked,
  COALESCE(t2.variants_out_of_stock, 0) AS variants_out_of_stock,
  {{divide_decimal(100.0 * COALESCE(t2.variants_out_of_stock, 0), t1.variants_tracked)}} AS pct_out_of_stock,
  COALESCE(t3.variants_at_or_below_reorder_point, 0) AS variants_at_or_below_reorder_point,
  {{divide_decimal(100.0 * COALESCE(t3.variants_at_or_below_reorder_point, 0), t1.variants_tracked)}} AS pct_at_or_below_reorder
FROM warehouses w0
JOIN tenants t9 ON t9.id = w0.tenant_id
JOIN (
  SELECT warehouse_id, COUNT(DISTINCT variant_id) AS variants_tracked
  FROM t0
  GROUP BY warehouse_id
) t1 ON t1.warehouse_id = w0.id
LEFT JOIN (
  SELECT warehouse_id, COUNT(*) AS variants_out_of_stock
  FROM t0
  WHERE (total_quantity - total_reserved_quantity) <= 0
  GROUP BY warehouse_id
) t2 ON t2.warehouse_id = w0.id
LEFT JOIN (
  SELECT warehouse_id, COUNT(*) AS variants_at_or_below_reorder_point
  FROM t0
  WHERE total_reorder_point IS NOT NULL AND total_quantity <= total_reorder_point
  GROUP BY warehouse_id
) t3 ON t3.warehouse_id = w0.id
WHERE t1.variants_tracked >= 20
ORDER BY pct_out_of_stock DESC NULLS FIRST, warehouse_name ASC NULLS LAST, w0.id ASC NULLS LAST
{{fetch_first(50)}}
