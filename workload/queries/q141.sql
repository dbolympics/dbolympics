SELECT
  t.industry AS industry,
  COUNT(*) FILTER (WHERE pr.created_at >= DATE '2024-12-01' AND pr.created_at < DATE '2025-01-01') AS dec2024_review_count,
  AVG(CAST(pr.rating AS NUMERIC(18,6))) FILTER (WHERE pr.created_at >= DATE '2024-12-01' AND pr.created_at < DATE '2025-01-01') AS dec2024_avg_rating,
  COUNT(*) FILTER (WHERE pr.created_at >= DATE '2025-12-01' AND pr.created_at < DATE '2026-01-01') AS dec2025_review_count,
  AVG(CAST(pr.rating AS NUMERIC(18,6))) FILTER (WHERE pr.created_at >= DATE '2025-12-01' AND pr.created_at < DATE '2026-01-01') AS dec2025_avg_rating,
  (AVG(CAST(pr.rating AS NUMERIC(18,6))) FILTER (WHERE pr.created_at >= DATE '2025-12-01' AND pr.created_at < DATE '2026-01-01')
- AVG(CAST(pr.rating AS NUMERIC(18,6))) FILTER (WHERE pr.created_at >= DATE '2024-12-01' AND pr.created_at < DATE '2025-01-01')) AS rating_change_pts,
  {{divide_decimal(100.0 * COUNT(*) FILTER (WHERE pr.created_at >= DATE '2025-12-01' AND pr.created_at < DATE '2026-01-01' AND pr.rating <= 2), NULLIF(COUNT(*) FILTER (WHERE pr.created_at >= DATE '2025-12-01' AND pr.created_at < DATE '2026-01-01'), 0))}} AS dec2025_pct_1_2_star
FROM product_reviews pr
JOIN products p ON p.id = pr.product_id AND p.tenant_id = pr.tenant_id
JOIN tenants t ON t.id = pr.tenant_id
WHERE pr.is_approved = true
  AND (
    (pr.created_at >= DATE '2024-12-01' AND pr.created_at < DATE '2025-01-01')
    OR (pr.created_at >= DATE '2025-12-01' AND pr.created_at < DATE '2026-01-01')
  )
GROUP BY t.industry
ORDER BY rating_change_pts ASC NULLS LAST, t.industry ASC NULLS LAST
