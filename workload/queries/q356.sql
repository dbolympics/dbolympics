WITH months AS (
  SELECT DISTINCT month_start
  FROM calendar_days
  WHERE month_start >= DATE '2023-01-01' AND month_start <= DATE '2025-12-01'
),
bundles AS (
  SELECT
    CAST({{date_trunc('month', created_at)}} AS date) AS month_start,
    COUNT(*) AS bundles_created_count,
    COUNT(DISTINCT tenant_id) AS distinct_tenants_creating_a_bundle
  FROM product_bundles
  GROUP BY 1
)
SELECT
  {{year_month(m.month_start)}} AS month,
  COALESCE(b.bundles_created_count, 0) AS bundles_created_count,
  COALESCE(b.distinct_tenants_creating_a_bundle, 0) AS distinct_tenants_creating_a_bundle
FROM months m
LEFT JOIN bundles b ON b.month_start = m.month_start
ORDER BY m.month_start NULLS LAST
