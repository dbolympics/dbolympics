WITH product_base AS (
  SELECT
    t0.id AS product_id,
    t0.tenant_id AS tenant_id,
    t0.status AS status,
    t0.created_at AS created_at,
    CASE
      WHEN COALESCE(t1.image_count, 0) = 0 THEN '0'
      WHEN COALESCE(t1.image_count, 0) = 1 THEN '1'
      WHEN COALESCE(t1.image_count, 0) BETWEEN 2 AND 3 THEN '2-3'
      WHEN COALESCE(t1.image_count, 0) BETWEEN 4 AND 6 THEN '4-6'
      ELSE '7+'
    END AS image_count_bucket
  FROM products t0
  LEFT JOIN (
    SELECT
      t1a.product_id AS product_id,
      COUNT(*) AS image_count
    FROM product_media t1a
    WHERE t1a.kind = 'image'
    GROUP BY t1a.product_id
  ) t1 ON t1.product_id = t0.id
),
dim_bucket AS (
  SELECT DISTINCT t2.image_count_bucket AS image_count_bucket
  FROM product_base t2
),
m_count AS (
  SELECT
    t3.image_count_bucket AS image_count_bucket,
    COUNT(*) AS product_count
  FROM product_base t3
  GROUP BY t3.image_count_bucket
),
m_age AS (
  SELECT
    t4.image_count_bucket AS image_count_bucket,
    AVG(CAST(DATE '2025-12-31' - CAST(t4.created_at AS date) AS numeric(18,6))) AS avg_days_since_created
  FROM product_base t4
  GROUP BY t4.image_count_bucket
),
m_status AS (
  SELECT
    t5.image_count_bucket AS image_count_bucket,
    {{divide_decimal(100.0 * SUM(CASE WHEN t5.status = 'draft' THEN 1 ELSE 0 END), COUNT(*))}} AS pct_status_draft,
    {{divide_decimal(100.0 * SUM(CASE WHEN t5.status = 'archived' THEN 1 ELSE 0 END), COUNT(*))}} AS pct_status_archived,
    {{divide_decimal(100.0 * SUM(CASE WHEN t5.status = 'active' THEN 1 ELSE 0 END), COUNT(*))}} AS pct_status_active
  FROM product_base t5
  GROUP BY t5.image_count_bucket
),
m_industry AS (
  SELECT
    t6.image_count_bucket AS image_count_bucket,
    {{divide_decimal(100.0 * SUM(CASE WHEN LOWER(t7.industry) LIKE '%apparel%' OR LOWER(t7.industry) LIKE '%footwear%' THEN 1 ELSE 0 END), COUNT(*))}} AS pct_apparel_footwear_industry,
    {{divide_decimal(100.0 * SUM(CASE WHEN LOWER(t7.industry) LIKE '%office%' OR LOWER(t7.industry) LIKE '%industrial%' THEN 1 ELSE 0 END), COUNT(*))}} AS pct_b2b_industry
  FROM product_base t6
  JOIN tenants t7 ON t7.id = t6.tenant_id
  GROUP BY t6.image_count_bucket
),
m_variants AS (
  SELECT
    t8.image_count_bucket AS image_count_bucket,
    AVG(CAST(COALESCE(t9.variant_count, 0) AS NUMERIC(18,6))) AS avg_variants_per_product
  FROM product_base t8
  LEFT JOIN (
    SELECT
      t9a.product_id AS product_id,
      COUNT(*) AS variant_count
    FROM product_variants t9a
    GROUP BY t9a.product_id
  ) t9 ON t9.product_id = t8.product_id
  GROUP BY t8.image_count_bucket
)
SELECT
  t10.image_count_bucket AS image_count_bucket,
  COALESCE(t11.product_count, 0) AS product_count,
  COALESCE(t12.avg_days_since_created, 0) AS avg_days_since_created,
  COALESCE(t13.pct_status_draft, 0) AS pct_status_draft,
  COALESCE(t13.pct_status_archived, 0) AS pct_status_archived,
  COALESCE(t13.pct_status_active, 0) AS pct_status_active,
  COALESCE(t14.pct_apparel_footwear_industry, 0) AS pct_apparel_footwear_industry,
  COALESCE(t14.pct_b2b_industry, 0) AS pct_b2b_industry,
  COALESCE(t15.avg_variants_per_product, 0) AS avg_variants_per_product
FROM dim_bucket t10
LEFT JOIN m_count t11 ON t11.image_count_bucket = t10.image_count_bucket
LEFT JOIN m_age t12 ON t12.image_count_bucket = t10.image_count_bucket
LEFT JOIN m_status t13 ON t13.image_count_bucket = t10.image_count_bucket
LEFT JOIN m_industry t14 ON t14.image_count_bucket = t10.image_count_bucket
LEFT JOIN m_variants t15 ON t15.image_count_bucket = t10.image_count_bucket
ORDER BY
  CASE t10.image_count_bucket
    WHEN '0' THEN 1
    WHEN '1' THEN 2
    WHEN '2-3' THEN 3
    WHEN '4-6' THEN 4
    WHEN '7+' THEN 5
  END NULLS LAST
