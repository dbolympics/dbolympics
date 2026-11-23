WITH products_agg AS (
  SELECT p.tenant_id AS tenant_id,
    count(*) AS active_product_count,
    count(*) FILTER (WHERE EXISTS (
      SELECT 1 FROM product_media pm WHERE pm.product_id = p.id AND pm.is_primary = true
    )) AS products_with_primary_image,
    count(*) FILTER (WHERE p.description IS NOT NULL AND length(trim(p.description)) > 0) AS products_with_description
  FROM products p
  WHERE p.status = 'active' AND p.deleted_at IS NULL
  GROUP BY p.tenant_id
),
variants_agg AS (
  SELECT p.tenant_id AS tenant_id,
    count(v.id) AS active_variant_count
  FROM products p
  JOIN product_variants v ON v.product_id = p.id AND v.is_active = true AND v.deleted_at IS NULL
  WHERE p.status = 'active' AND p.deleted_at IS NULL
  GROUP BY p.tenant_id
),
reviews_agg AS (
  SELECT p.tenant_id AS tenant_id,
    count(r.id) AS approved_review_count,
    avg(cast(r.rating as numeric(18,6))) AS avg_rating
  FROM products p
  JOIN product_reviews r ON r.product_id = p.id AND r.is_approved = true
  WHERE p.status = 'active' AND p.deleted_at IS NULL
  GROUP BY p.tenant_id
),
orders_agg AS (
  SELECT o.tenant_id AS tenant_id,
    count(*) AS orders_last_12mo,
    sum(CAST({{divide_decimal(o.grand_total, COALESCE(er.rate, CASE WHEN o.currency_code = 'EUR' THEN 1 END))}} AS NUMERIC(18,6))) AS revenue_eur
  FROM orders o
  LEFT JOIN exchange_rates er
    ON er.base_code = 'EUR'
   AND er.quote_code = o.currency_code
   AND er.as_of = CAST(o.placed_at AS date)
  WHERE o.placed_at >= DATE '2025-01-01'
    AND o.placed_at < DATE '2026-01-01'
    AND o.status <> 'cancelled'
  GROUP BY o.tenant_id
)
SELECT
  t.name AS merchant_name,
  t.industry AS industry,
  COALESCE(pa.active_product_count, 0) AS active_product_count,
  COALESCE(va.active_variant_count, 0) AS active_variant_count,
  {{divide_decimal(CAST(COALESCE(va.active_variant_count, 0) AS numeric(18,6)), NULLIF(pa.active_product_count, 0))}} AS avg_variants_per_product,
  {{divide_decimal(100.0 * COALESCE(pa.products_with_primary_image, 0), NULLIF(pa.active_product_count, 0))}} AS pct_products_with_primary_image,
  {{divide_decimal(100.0 * COALESCE(pa.products_with_description, 0), NULLIF(pa.active_product_count, 0))}} AS pct_products_with_description,
  {{divide_decimal(CAST(COALESCE(ra.approved_review_count, 0) AS numeric(18,6)), NULLIF(pa.active_product_count, 0))}} AS avg_reviews_per_product,
  ra.avg_rating AS avg_rating,
  COALESCE(oa.orders_last_12mo, 0) AS orders_last_12mo,
  COALESCE(oa.revenue_eur, 0) AS revenue_eur_last_12mo
FROM tenants t
LEFT JOIN products_agg pa ON pa.tenant_id = t.id
LEFT JOIN variants_agg va ON va.tenant_id = t.id
LEFT JOIN reviews_agg ra ON ra.tenant_id = t.id
LEFT JOIN orders_agg oa ON oa.tenant_id = t.id
WHERE t.deleted_at IS NULL
ORDER BY revenue_eur_last_12mo DESC NULLS FIRST, merchant_name ASC NULLS LAST, t.id NULLS LAST
{{fetch_first(50)}}
