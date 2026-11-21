SELECT p.name as product_name,
       c.name as category_name,
       r.review_count AS review_count,
       r.avg_rating AS avg_rating,
       r.pct_1_2_star AS pct_1_2_star,
       (SELECT COALESCE(SUM(oi.quantity),0)
        FROM order_items oi
        JOIN orders o ON o.id = oi.order_id
        WHERE o.tenant_id = p.tenant_id
          AND o.status <> 'cancelled'
          AND o.placed_at >= timestamp '2025-01-01' AND o.placed_at < timestamp '2026-01-01'
          AND oi.product_variant_id IN (SELECT pv.id FROM product_variants pv WHERE pv.product_id = p.id)
       ) AS units_sold_last_12mo
FROM products p
JOIN categories c ON c.id = p.primary_category_id
JOIN (
   SELECT pr.product_id AS product_id,
          COUNT(*) AS review_count,
          AVG(CAST(pr.rating AS NUMERIC(18,6))) AS avg_rating,
          {{divide_decimal(100.0 * SUM(CASE WHEN pr.rating IN (1,2) THEN 1 ELSE 0 END), COUNT(*))}} AS pct_1_2_star
   FROM product_reviews pr
   WHERE pr.is_approved = true
     AND pr.created_at >= timestamp '2025-12-01' AND pr.created_at < timestamp '2026-01-01'
     AND pr.tenant_id = (SELECT id FROM tenants WHERE name = 'Wiesgrund Wohnen')
   GROUP BY pr.product_id
) r ON r.product_id = p.id
WHERE p.tenant_id = (SELECT id FROM tenants WHERE name = 'Wiesgrund Wohnen')
ORDER BY r.review_count DESC NULLS FIRST, r.avg_rating ASC NULLS LAST, p.name ASC NULLS LAST, p.id ASC NULLS LAST
