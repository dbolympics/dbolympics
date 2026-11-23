SELECT t.name AS merchant_name,
       d.review_count AS dec2025_review_count,
       d.avg_rating AS dec2025_avg_rating,
       d.pct_1_2_star AS dec2025_pct_1_2_star,
       j.avg_rating AS jan_to_nov_2025_avg_rating,
       d.avg_rating - j.avg_rating AS rating_change_pts
FROM tenants t
JOIN (
  SELECT p.tenant_id AS tenant_id,
         COUNT(*) AS review_count,
         AVG(CAST(pr.rating AS NUMERIC(18,6))) AS avg_rating,
         {{divide_decimal(100.0 * SUM(CASE WHEN pr.rating <= 2 THEN 1 ELSE 0 END), COUNT(*))}} AS pct_1_2_star
  FROM product_reviews pr
  JOIN products p ON pr.product_id = p.id
  WHERE pr.is_approved = true
    AND pr.created_at >= DATE '2025-12-01'
    AND pr.created_at < DATE '2026-01-01'
  GROUP BY p.tenant_id
) d ON d.tenant_id = t.id
JOIN (
  SELECT p.tenant_id AS tenant_id,
         AVG(CAST(pr.rating AS NUMERIC(18,6))) AS avg_rating
  FROM product_reviews pr
  JOIN products p ON pr.product_id = p.id
  WHERE pr.is_approved = true
    AND pr.created_at >= DATE '2025-01-01'
    AND pr.created_at < DATE '2025-12-01'
  GROUP BY p.tenant_id
) j ON j.tenant_id = t.id
WHERE t.industry = 'Home & Living'
ORDER BY rating_change_pts ASC NULLS LAST, d.review_count DESC NULLS FIRST, t.id ASC NULLS LAST
