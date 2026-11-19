WITH product_images AS (
  SELECT product_id, COUNT(*) AS image_count
  FROM product_media
  WHERE kind = 'image'
  GROUP BY product_id
),
base AS (
  SELECT p.id AS product_id,
         COALESCE(pi.image_count,0) AS image_count,
         CASE WHEN p.description IS NOT NULL AND p.description <> '' THEN 1 ELSE 0 END AS has_description
  FROM products p
  LEFT JOIN product_images pi ON pi.product_id = p.id
  WHERE p.status = 'active' AND p.deleted_at IS NULL
),
bucketed AS (
  SELECT product_id, has_description,
    CASE
      WHEN image_count = 0 THEN '0'
      WHEN image_count = 1 THEN '1'
      WHEN image_count BETWEEN 2 AND 3 THEN '2-3'
      WHEN image_count BETWEEN 4 AND 6 THEN '4-6'
      ELSE '7+'
    END AS image_count_bucket,
    CASE
      WHEN image_count = 0 THEN 0
      WHEN image_count = 1 THEN 1
      WHEN image_count BETWEEN 2 AND 3 THEN 2
      WHEN image_count BETWEEN 4 AND 6 THEN 3
      ELSE 4
    END AS bucket_order
  FROM base
),
reviews AS (
  SELECT product_id, COUNT(*) AS review_count, AVG(CAST(rating AS NUMERIC(18,6))) AS avg_rating
  FROM product_reviews
  GROUP BY product_id
),
sales AS (
  SELECT pv.product_id AS product_id,
         SUM(oi.quantity) AS units_sold,
         SUM(CAST({{divide_decimal(oi.line_total, er.rate)}} AS NUMERIC(18,6))) AS revenue_eur
  FROM order_items oi
  JOIN orders o ON o.id = oi.order_id
  JOIN product_variants pv ON pv.id = oi.product_variant_id
  JOIN exchange_rates er ON er.base_code = 'EUR' AND er.quote_code = oi.currency_code AND er.as_of = CAST(o.placed_at AS DATE)
  WHERE o.placed_at >= DATE '2025-01-01' AND o.placed_at < DATE '2026-01-01'
    AND o.status <> 'cancelled'
  GROUP BY pv.product_id
)
SELECT
  b.image_count_bucket AS image_count_bucket,
  COUNT(*) AS product_count,
  {{divide_decimal(100.0 * SUM(b.has_description), COUNT(*))}} AS pct_with_description,
  AVG(CAST(COALESCE(r.review_count,0) AS NUMERIC(18,6))) AS avg_reviews_per_product,
  AVG(r.avg_rating) AS avg_rating,
  AVG(CAST(COALESCE(s.units_sold,0) AS NUMERIC(18,6))) AS avg_units_sold_per_product_last_12mo,
  AVG(COALESCE(s.revenue_eur,0)) AS avg_revenue_per_product_eur_last_12mo
FROM bucketed b
LEFT JOIN reviews r ON r.product_id = b.product_id
LEFT JOIN sales s ON s.product_id = b.product_id
GROUP BY b.image_count_bucket, b.bucket_order
ORDER BY b.bucket_order NULLS LAST
