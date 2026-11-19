WITH months AS (
  SELECT DISTINCT t0.month_label AS month, t0.month_start AS month_start
  FROM calendar_days t0
  WHERE t0.month_start >= DATE '2023-01-01' AND t0.month_start < DATE '2026-01-01'
),
reviews AS (
  SELECT t1.month_label AS month, t0.rating AS rating, t0.is_verified_purchase AS is_verified_purchase
  FROM product_reviews t0
  JOIN calendar_days t1 ON t1.calendar_date = CAST(t0.created_at AS date)
  WHERE t0.is_approved = true
),
m_count AS (
  SELECT t2.month AS month, COUNT(*) AS review_count
  FROM reviews t2
  GROUP BY t2.month
),
m_avg AS (
  SELECT t3.month AS month, AVG(CAST(t3.rating AS NUMERIC(18,6))) AS avg_rating
  FROM reviews t3
  GROUP BY t3.month
),
m_low AS (
  SELECT t4.month AS month, SUM(CASE WHEN t4.rating IN (1,2) THEN 1 ELSE 0 END) AS low_count
  FROM reviews t4
  GROUP BY t4.month
),
m_five AS (
  SELECT t5.month AS month, SUM(CASE WHEN t5.rating = 5 THEN 1 ELSE 0 END) AS five_count
  FROM reviews t5
  GROUP BY t5.month
),
m_verified AS (
  SELECT t6.month AS month, SUM(CASE WHEN t6.is_verified_purchase THEN 1 ELSE 0 END) AS verified_count
  FROM reviews t6
  GROUP BY t6.month
)
SELECT
  t0.month AS month,
  COALESCE(t1.review_count, 0) AS review_count,
  COALESCE(t2.avg_rating, 0) AS avg_rating,
  {{divide_decimal(100.0 * COALESCE(t3.low_count, 0), NULLIF(t1.review_count, 0))}} AS pct_1_2_star,
  {{divide_decimal(100.0 * COALESCE(t4.five_count, 0), NULLIF(t1.review_count, 0))}} AS pct_5_star,
  {{divide_decimal(100.0 * COALESCE(t5.verified_count, 0), NULLIF(t1.review_count, 0))}} AS pct_verified_purchase
FROM months t0
LEFT JOIN m_count t1 ON t1.month = t0.month
LEFT JOIN m_avg t2 ON t2.month = t0.month
LEFT JOIN m_low t3 ON t3.month = t0.month
LEFT JOIN m_five t4 ON t4.month = t0.month
LEFT JOIN m_verified t5 ON t5.month = t0.month
ORDER BY t0.month_start NULLS LAST, t0.month NULLS LAST
