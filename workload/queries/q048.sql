WITH base AS (
  SELECT
    {{date_trunc('month', t.created_at)}} AS month_start,
    t.rating AS rating,
    t.is_verified_purchase AS is_verified_purchase
  FROM product_reviews t
  WHERE t.is_approved = true
    AND t.created_at >= DATE '2023-01-01'
    AND t.created_at < DATE '2026-01-01'
)
SELECT
  {{year_month(t0.month_start)}} AS month,
  t0.review_count AS reviews_submitted,
  t1.avg_rating AS avg_rating,
  t2.median_rating AS median_rating,
  t3.pct_low_rating AS pct_low_rating,
  t3.pct_high_rating AS pct_high_rating,
  t3.pct_verified_purchase AS pct_verified_purchase
FROM (
  SELECT month_start, COUNT(*) AS review_count
  FROM base
  GROUP BY month_start
) t0
JOIN (
  SELECT month_start, AVG(CAST(rating AS NUMERIC(18,6))) AS avg_rating
  FROM base
  GROUP BY month_start
) t1 ON t1.month_start = t0.month_start
JOIN (
  SELECT month_start, {{percentile_cont(0.5, rating)}} AS median_rating
  FROM base
  GROUP BY month_start
) t2 ON t2.month_start = t0.month_start
JOIN (
  SELECT
    month_start,
    100.0 * SUM(CASE WHEN rating IN (1,2) THEN 1 ELSE 0 END) / COUNT(*) AS pct_low_rating,
    100.0 * SUM(CASE WHEN rating IN (4,5) THEN 1 ELSE 0 END) / COUNT(*) AS pct_high_rating,
    100.0 * SUM(CASE WHEN is_verified_purchase THEN 1 ELSE 0 END) / COUNT(*) AS pct_verified_purchase
  FROM base
  GROUP BY month_start
) t3 ON t3.month_start = t0.month_start
ORDER BY t0.month_start ASC NULLS LAST
