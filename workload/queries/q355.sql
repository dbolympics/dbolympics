WITH active_tenants AS (
  SELECT id AS tenant_id, industry
  FROM tenants
  WHERE deleted_at IS NULL
),
bundle_using_tenants AS (
  SELECT DISTINCT tenant_id
  FROM product_bundles
  WHERE is_active = true
),
active_products AS (
  SELECT tenant_id, id AS product_id
  FROM products
  WHERE status = 'active' AND deleted_at IS NULL
),
bundled_product_ids AS (
  SELECT DISTINCT pv.tenant_id AS tenant_id, pv.product_id AS product_id
  FROM bundle_items bi
  JOIN product_bundles pb
    ON pb.id = bi.bundle_id AND pb.tenant_id = bi.tenant_id
  JOIN product_variants pv
    ON pv.id = bi.variant_id AND pv.tenant_id = bi.tenant_id
  WHERE pb.is_active = true
),
tenant_bundle_counts AS (
  SELECT
    ap.tenant_id AS tenant_id,
    COUNT(DISTINCT ap.product_id) AS active_product_count,
    COUNT(DISTINCT bp.product_id) AS bundled_active_product_count
  FROM active_products ap
  LEFT JOIN bundled_product_ids bp
    ON bp.tenant_id = ap.tenant_id AND bp.product_id = ap.product_id
  GROUP BY ap.tenant_id
),
tenant_pct AS (
  SELECT
    tenant_id,
    CASE WHEN active_product_count > 0
      THEN {{divide_decimal(CAST(bundled_active_product_count AS decimal(18,6)), active_product_count)}} * 100
      ELSE NULL END AS pct_active_products_in_a_bundle
  FROM tenant_bundle_counts
),
tenant_summary AS (
  SELECT
    ten.tenant_id AS tenant_id,
    COALESCE(ten.industry, 'Unknown') AS industry,
    CASE WHEN bu.tenant_id IS NOT NULL THEN 1 ELSE 0 END AS uses_bundles,
    tp.pct_active_products_in_a_bundle AS pct_active_products_in_a_bundle
  FROM active_tenants ten
  LEFT JOIN bundle_using_tenants bu ON bu.tenant_id = ten.tenant_id
  LEFT JOIN tenant_pct tp ON tp.tenant_id = ten.tenant_id
)
SELECT
  industry,
  COUNT(*) AS merchant_count,
  SUM(uses_bundles) AS merchants_using_bundles,
  {{divide_decimal(CAST(SUM(uses_bundles) AS decimal(18,6)), COUNT(*))}} * 100 AS pct_merchants_using_bundles,
  AVG(CASE WHEN uses_bundles = 1 THEN pct_active_products_in_a_bundle END) AS avg_pct_products_bundled_among_users
FROM tenant_summary
GROUP BY industry
ORDER BY pct_merchants_using_bundles DESC NULLS FIRST, industry ASC NULLS LAST
