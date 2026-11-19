WITH revenue AS (
  SELECT
    o.tenant_id AS tenant_id,
    SUM(
      {{divide_decimal(o.grand_total, CASE WHEN o.currency_code = 'EUR' THEN 1 ELSE er.rate END)}}
    ) AS revenue_eur
  FROM orders o
  LEFT JOIN exchange_rates er
    ON er.base_code = 'EUR'
    AND er.quote_code = o.currency_code
    AND er.as_of = CAST(o.placed_at AS date)
  WHERE o.placed_at >= DATE '2025-01-01'
    AND o.placed_at < DATE '2026-01-01'
    AND o.status <> 'cancelled'
  GROUP BY o.tenant_id
),
top50 AS (
  SELECT tenant_id, revenue_eur,
    ROW_NUMBER() OVER (ORDER BY revenue_eur DESC NULLS FIRST, tenant_id NULLS LAST) AS rn
  FROM revenue
),
product_stats AS (
  SELECT
    p.tenant_id AS tenant_id,
    p.id AS product_id,
    COUNT(pr.id) AS review_count,
    AVG(CAST(pr.rating AS NUMERIC(18,6))) AS avg_rating
  FROM products p
  JOIN product_reviews pr
    ON pr.product_id = p.id
    AND pr.is_approved = true
  GROUP BY p.tenant_id, p.id
  HAVING COUNT(pr.id) >= 5
),
merchant_agg AS (
  SELECT
    tenant_id,
    COUNT(*) AS products_with_5plus_reviews,
    COUNT(*) FILTER (WHERE avg_rating < 3.0) AS poor_rated_product_count
  FROM product_stats
  GROUP BY tenant_id
)
SELECT
  t.name AS merchant_name,
  t.industry AS industry,
  COALESCE(ma.products_with_5plus_reviews, 0) AS products_with_5plus_reviews,
  COALESCE(ma.poor_rated_product_count, 0) AS poor_rated_product_count,
  CASE
    WHEN COALESCE(ma.products_with_5plus_reviews, 0) = 0 THEN NULL
    ELSE {{divide_decimal(CAST(ma.poor_rated_product_count AS numeric(18,6)), ma.products_with_5plus_reviews)}} * 100
  END AS pct_poor_rated_products,
  r.revenue_eur AS revenue_eur_last_12mo
FROM top50 r
JOIN tenants t ON t.id = r.tenant_id
LEFT JOIN merchant_agg ma ON ma.tenant_id = r.tenant_id
WHERE r.rn <= 50
ORDER BY
  poor_rated_product_count DESC NULLS FIRST,
  pct_poor_rated_products DESC NULLS LAST,
  merchant_name NULLS LAST,
  t.id NULLS LAST
