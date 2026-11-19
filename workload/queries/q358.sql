SELECT
  p.name AS product_name,
  c.name AS category_name,
  (SELECT COUNT(*) FROM product_reviews pr
     WHERE pr.product_id = p.id AND pr.tenant_id = p.tenant_id
       AND pr.is_approved = true
       AND pr.created_at >= DATE '2025-12-01' AND pr.created_at < DATE '2026-01-01'
  ) AS review_count,
  (SELECT AVG(CAST(pr.rating AS NUMERIC(18,6))) FROM product_reviews pr
     WHERE pr.product_id = p.id AND pr.tenant_id = p.tenant_id
       AND pr.is_approved = true
       AND pr.created_at >= DATE '2025-12-01' AND pr.created_at < DATE '2026-01-01'
  ) AS avg_rating,
  (SELECT {{divide_decimal(100.0 * SUM(CASE WHEN pr.rating <= 2 THEN 1 ELSE 0 END), COUNT(*))}} FROM product_reviews pr
     WHERE pr.product_id = p.id AND pr.tenant_id = p.tenant_id
       AND pr.is_approved = true
       AND pr.created_at >= DATE '2025-12-01' AND pr.created_at < DATE '2026-01-01'
  ) AS pct_1_2_star,
  (SELECT COALESCE(SUM(oi.quantity), 0)
     FROM order_items oi
     JOIN orders o ON o.id = oi.order_id
     WHERE oi.tenant_id = p.tenant_id
       AND o.tenant_id = p.tenant_id
       AND o.status != 'cancelled'
       AND o.placed_at >= DATE '2025-01-01' AND o.placed_at < DATE '2026-01-01'
       AND oi.product_variant_id IN (SELECT pv.id FROM product_variants pv WHERE pv.product_id = p.id)
  ) AS units_sold_last_12mo
FROM products p
LEFT JOIN categories c ON c.id = p.primary_category_id
WHERE p.tenant_id = (SELECT t.id AS id FROM tenants t WHERE t.name = 'Fennel & Flint')
  AND EXISTS (
    SELECT 1 FROM product_reviews pr
    WHERE pr.product_id = p.id AND pr.tenant_id = p.tenant_id
      AND pr.is_approved = true
      AND pr.created_at >= DATE '2025-12-01' AND pr.created_at < DATE '2026-01-01'
  )
ORDER BY review_count DESC NULLS FIRST, avg_rating ASC NULLS LAST, p.id ASC NULLS LAST
