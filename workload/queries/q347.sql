SELECT
  c.name AS category_name,
  pc.product_count AS product_count,
  COALESCE(pr.products_5plus, 0) AS products_with_5plus_reviews,
  COALESCE(pr.poor_rated_count, 0) AS poor_rated_product_count,
  CASE WHEN COALESCE(pr.products_5plus,0) = 0 THEN NULL
       ELSE {{divide_decimal(CAST(pr.poor_rated_count AS numeric(18,6)), pr.products_5plus)}} * 100
  END AS pct_poor_rated_products,
  pr.avg_rating AS avg_rating_of_reviewed_products,
  COALESCE(rv.units_sold, 0) AS units_sold_last_12mo,
  COALESCE(rv.revenue_eur, 0) AS revenue_eur_last_12mo
FROM categories c
JOIN (
  SELECT p.primary_category_id AS primary_category_id, COUNT(*) AS product_count
  FROM products p
  WHERE p.tenant_id = (SELECT id FROM tenants WHERE name = 'Cragsley Outfitters')
    AND p.primary_category_id IS NOT NULL
  GROUP BY p.primary_category_id
) pc ON pc.primary_category_id = c.id
LEFT JOIN (
  SELECT p.primary_category_id AS primary_category_id,
    COUNT(*) FILTER (WHERE rc.review_count >= 5) AS products_5plus,
    COUNT(*) FILTER (WHERE rc.review_count >= 5 AND rc.avg_rating < 3.0) AS poor_rated_count,
    AVG(rc.avg_rating) FILTER (WHERE rc.review_count >= 5) AS avg_rating
  FROM products p
  JOIN (
    SELECT product_id, COUNT(*) AS review_count, AVG(CAST(rating AS NUMERIC(18,6))) AS avg_rating
    FROM product_reviews
    WHERE is_approved = true
    GROUP BY product_id
  ) rc ON rc.product_id = p.id
  WHERE p.tenant_id = (SELECT id FROM tenants WHERE name = 'Cragsley Outfitters')
  GROUP BY p.primary_category_id
) pr ON pr.primary_category_id = c.id
LEFT JOIN (
  SELECT p.primary_category_id AS primary_category_id,
    SUM(oi.quantity) AS units_sold,
    SUM(CASE WHEN oi.currency_code = 'EUR' THEN CAST(oi.line_total AS NUMERIC(18,6)) ELSE CAST({{divide_decimal(oi.line_total, er.rate)}} AS NUMERIC(18,6)) END) AS revenue_eur
  FROM order_items oi
  JOIN orders o ON o.id = oi.order_id
  JOIN product_variants pv ON pv.id = oi.product_variant_id
  JOIN products p ON p.id = pv.product_id
  LEFT JOIN exchange_rates er
    ON er.base_code = 'EUR'
    AND er.quote_code = oi.currency_code
    AND er.as_of = CAST(o.placed_at AS date)
  WHERE o.tenant_id = (SELECT id FROM tenants WHERE name = 'Cragsley Outfitters')
    AND o.placed_at >= DATE '2025-01-01'
    AND o.placed_at < DATE '2026-01-01'
    AND o.status <> 'cancelled'
    AND p.status = 'active'
  GROUP BY p.primary_category_id
) rv ON rv.primary_category_id = c.id
WHERE c.tenant_id = (SELECT id FROM tenants WHERE name = 'Cragsley Outfitters')
ORDER BY poor_rated_product_count DESC NULLS FIRST, pct_poor_rated_products DESC NULLS LAST, category_name NULLS LAST, c.id NULLS LAST
