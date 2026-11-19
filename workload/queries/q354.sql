SELECT t.name AS merchant_name, y.year AS year,
  COALESCE(r.dec_review_count,0) AS dec_review_count,
  r.dec_avg_rating AS dec_avg_rating,
  r.dec_pct_1_2_star AS dec_pct_1_2_star,
  COALESCE(o.dec_orders_count,0) AS dec_orders_count
FROM tenants t
CROSS JOIN (VALUES (2023),(2024),(2025)) AS y(year)
LEFT JOIN (
  SELECT tenant_id,
    CAST(EXTRACT(YEAR FROM created_at) AS int) AS yr,
    COUNT(*) AS dec_review_count,
    AVG(CAST(rating AS NUMERIC(18,6))) AS dec_avg_rating,
    {{divide_decimal(100.0*SUM(CASE WHEN rating<=2 THEN 1 ELSE 0 END), COUNT(*))}} AS dec_pct_1_2_star
  FROM product_reviews
  WHERE is_approved = true AND EXTRACT(MONTH FROM created_at) = 12
  GROUP BY tenant_id, EXTRACT(YEAR FROM created_at)
) r ON r.tenant_id = t.id AND r.yr = y.year
LEFT JOIN (
  SELECT tenant_id,
    CAST(EXTRACT(YEAR FROM placed_at) AS int) AS yr,
    COUNT(*) AS dec_orders_count
  FROM orders
  WHERE status <> 'cancelled' AND EXTRACT(MONTH FROM placed_at) = 12
  GROUP BY tenant_id, EXTRACT(YEAR FROM placed_at)
) o ON o.tenant_id = t.id AND o.yr = y.year
WHERE t.name IN ('Fennel & Flint','Wiesgrund Wohnen')
ORDER BY t.name NULLS LAST, y.year NULLS LAST, t.id NULLS LAST
