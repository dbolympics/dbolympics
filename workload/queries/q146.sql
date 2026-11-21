WITH order_item_sales AS (
  SELECT
    pv.product_id AS product_id,
    oi.quantity AS quantity,
    oi.line_total AS line_total,
    o.currency_code AS currency_code,
    o.placed_at AS placed_at
  FROM order_items oi
  JOIN orders o ON oi.order_id = o.id
  JOIN product_variants pv ON oi.product_variant_id = pv.id
  WHERE o.placed_at >= timestamp '2025-01-01'
    AND o.placed_at < timestamp '2026-01-01'
    AND o.status <> 'cancelled'
),
rates AS (
  SELECT quote_code, as_of, rate
  FROM exchange_rates
  WHERE base_code = 'EUR'
),
sales_eur AS (
  SELECT
    s.product_id AS product_id,
    SUM(s.quantity) AS units_sold,
    SUM(CAST({{divide_decimal(s.line_total, r.rate)}} AS NUMERIC(18,6))) AS revenue_eur
  FROM order_item_sales s
  JOIN rates r
    ON r.quote_code = s.currency_code
   AND r.as_of = CAST(s.placed_at AS date)
  GROUP BY s.product_id
),
reviews AS (
  SELECT
    product_id,
    COUNT(*) AS review_count,
    AVG(CAST(rating AS NUMERIC(18,6))) AS avg_rating
  FROM product_reviews
  WHERE is_approved = true
  GROUP BY product_id
),
product_info AS (
  SELECT
    p.id AS id,
    p.name AS product_name,
    p.tenant_id AS tenant_id,
    p.status AS status,
    p.deleted_at AS deleted_at
  FROM products p
)
SELECT
  pi.product_name AS product_name,
  t.name AS merchant_name,
  t.industry AS industry,
  se.units_sold AS units_sold_last_12mo,
  se.revenue_eur AS revenue_eur_last_12mo,
  COALESCE(r.review_count, 0) AS review_count,
  r.avg_rating AS avg_rating
FROM sales_eur se
JOIN product_info pi ON pi.id = se.product_id
JOIN tenants t ON t.id = pi.tenant_id
LEFT JOIN reviews r ON r.product_id = se.product_id
WHERE pi.status = 'active'
  AND pi.deleted_at IS NULL
  AND se.units_sold >= 30
  AND COALESCE(r.review_count, 0) <= 2
ORDER BY se.units_sold DESC NULLS FIRST, se.revenue_eur DESC NULLS FIRST, pi.product_name NULLS LAST, se.product_id NULLS LAST
{{fetch_first(50)}}
