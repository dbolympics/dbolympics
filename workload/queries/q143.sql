WITH reviews AS (
  SELECT product_id,
         count(*) AS review_count,
         avg(cast(rating as numeric(18,6))) AS avg_rating,
         {{divide_decimal(CAST(sum(case when rating in (1,2) then 1 else 0 end) AS numeric(18,6)), count(*))}} * 100 AS pct_1_2
  FROM product_reviews
  WHERE is_approved = true
  GROUP BY product_id
),
sales AS (
  SELECT pv.product_id AS product_id, sum(oi.quantity) AS units_sold
  FROM order_items oi
  JOIN product_variants pv ON pv.id = oi.product_variant_id
  JOIN orders o ON o.id = oi.order_id
  WHERE o.placed_at >= DATE '2025-01-01' AND o.placed_at < DATE '2026-01-01'
    AND o.status <> 'cancelled'
  GROUP BY pv.product_id
)
SELECT p.name AS product_name,
       t.name AS merchant_name,
       t.industry AS industry,
       r.review_count AS review_count,
       r.avg_rating AS avg_rating,
       r.pct_1_2 AS pct_1_2_star,
       coalesce(s.units_sold, 0) AS units_sold_last_12mo
FROM products p
JOIN reviews r ON r.product_id = p.id
JOIN tenants t ON t.id = p.tenant_id
LEFT JOIN sales s ON s.product_id = p.id
WHERE r.review_count >= 5
ORDER BY avg_rating ASC NULLS LAST, r.review_count DESC NULLS FIRST, p.id ASC NULLS LAST
{{fetch_first(50)}}
