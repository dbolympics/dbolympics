SELECT
  t0.month_label AS month,
  COALESCE(t1.orders_count, 0) AS orders_count,
  COALESCE(t2.review_count, 0) AS review_count,
  CASE WHEN COALESCE(t1.orders_count, 0) = 0 THEN 0
  ELSE CAST(COALESCE(t2.review_count, 0) AS decimal(18,6)) / t1.orders_count * 100
  END AS reviews_per_100_orders,
  COALESCE(t2.avg_rating, 0) AS avg_rating
FROM (
  SELECT DISTINCT month_label, month_start
  FROM calendar_days
  WHERE calendar_date >= DATE '2023-01-01' AND calendar_date <= DATE '2025-12-31'
) t0
LEFT JOIN (
  SELECT
    CAST({{date_trunc('month', o.placed_at)}} AS date) AS month_start,
    COUNT(*) AS orders_count
  FROM orders o
  WHERE o.placed_at IS NOT NULL
    AND o.status NOT IN ('cancelled')
  GROUP BY CAST({{date_trunc('month', o.placed_at)}} AS date)
) t1 ON t1.month_start = t0.month_start
LEFT JOIN (
  SELECT
    CAST({{date_trunc('month', r.created_at)}} AS date) AS month_start,
    COUNT(*) AS review_count,
    AVG(CAST(r.rating AS NUMERIC(18,6))) AS avg_rating
  FROM product_reviews r
  WHERE r.is_approved = true
  GROUP BY CAST({{date_trunc('month', r.created_at)}} AS date)
) t2 ON t2.month_start = t0.month_start
ORDER BY t0.month_start ASC NULLS LAST, t0.month_label ASC NULLS LAST
