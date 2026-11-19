WITH base AS (
  SELECT
    w.id AS warehouse_id,
    w.name AS warehouse_name,
    t.name AS tenant_name,
    sa.reason AS reason,
    sa.adjusted_by_user_id AS adjusted_by_user_id
  FROM stock_adjustments sa
  JOIN stock_locations sl ON sl.id = sa.stock_location_id
  JOIN warehouses w ON w.id = sl.warehouse_id
  JOIN tenants t ON t.id = w.tenant_id
  WHERE sa.created_at >= DATE '2025-01-01' AND sa.created_at < DATE '2026-01-01'
),
agg AS (
  SELECT
    warehouse_id,
    warehouse_name,
    tenant_name,
    COUNT(*) AS total_adjustments_at_site,
    COUNT(*) FILTER (WHERE reason = 'Missing - suspected theft') AS theft_tagged_count,
    COUNT(DISTINCT adjusted_by_user_id) FILTER (WHERE reason = 'Missing - suspected theft') AS distinct_staff_logging_theft_here
  FROM base
  GROUP BY warehouse_id, warehouse_name, tenant_name
)
SELECT
  warehouse_name,
  tenant_name,
  total_adjustments_at_site,
  theft_tagged_count,
  {{divide_decimal(theft_tagged_count * 100.0, NULLIF(total_adjustments_at_site, 0))}} AS pct_theft_of_site_adjustments,
  distinct_staff_logging_theft_here,
  COUNT(*) OVER () AS total_warehouses_with_adjustments_2025
FROM agg
ORDER BY theft_tagged_count DESC NULLS FIRST, pct_theft_of_site_adjustments DESC NULLS FIRST, warehouse_name ASC NULLS LAST, warehouse_id NULLS LAST
{{fetch_first(50)}}
