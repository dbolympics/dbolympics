WITH tenant_cte AS (
  SELECT id AS tenant_id FROM tenants WHERE name = 'Cragsley Outfitters'
),
poor_tier AS (
  SELECT pr.product_id AS product_id
  FROM product_reviews pr
  JOIN tenant_cte t ON pr.tenant_id = t.tenant_id
  WHERE pr.is_approved = true
  GROUP BY pr.product_id
  HAVING count(*) >= 5 AND avg(cast(pr.rating as numeric(18,6))) < 3.0
),
other_tier AS (
  SELECT p.id AS product_id
  FROM products p
  JOIN tenant_cte t ON p.tenant_id = t.tenant_id
  WHERE p.status = 'active'
    AND p.id NOT IN (SELECT product_id FROM poor_tier)
),
months AS (
  SELECT DISTINCT month_start AS month
  FROM calendar_days
  WHERE month_start BETWEEN DATE '2023-01-01' AND DATE '2025-12-01'
),
line_items AS (
  SELECT
    CAST({{date_trunc('month', o.placed_at)}} AS date) AS month,
    pv.product_id AS product_id,
    oi.quantity AS quantity,
    oi.line_total AS line_total,
    oi.currency_code AS currency_code,
    CAST(o.placed_at AS date) AS placed_date
  FROM order_items oi
  JOIN orders o ON oi.order_id = o.id
  JOIN product_variants pv ON oi.product_variant_id = pv.id
  JOIN tenant_cte t ON o.tenant_id = t.tenant_id
  WHERE o.status <> 'cancelled'
    AND o.placed_at >= DATE '2023-01-01'
    AND o.placed_at < DATE '2026-01-01'
),
converted AS (
  SELECT
    li.month AS month,
    li.product_id AS product_id,
    li.quantity AS quantity,
    CASE WHEN li.currency_code = 'EUR' THEN li.line_total
         ELSE CAST(li.line_total / er.rate AS NUMERIC(18,6)) END AS revenue_eur
  FROM line_items li
  LEFT JOIN exchange_rates er
    ON er.base_code = 'EUR' AND er.quote_code = li.currency_code AND er.as_of = li.placed_date
),
tiered AS (
  SELECT c.month AS month,
    CASE WHEN c.product_id IN (SELECT product_id FROM poor_tier) THEN 'poor'
         WHEN c.product_id IN (SELECT product_id FROM other_tier) THEN 'other'
         ELSE NULL END AS tier,
    c.quantity AS quantity,
    c.revenue_eur AS revenue_eur
  FROM converted c
)
SELECT
  m.month AS month,
  COALESCE(SUM(CASE WHEN t.tier='poor' THEN t.quantity END),0) AS poor_tier_units_sold,
  COALESCE(SUM(CASE WHEN t.tier='poor' THEN t.revenue_eur END),0) AS poor_tier_revenue_eur,
  COALESCE(SUM(CASE WHEN t.tier='other' THEN t.quantity END),0) AS other_tier_units_sold,
  COALESCE(SUM(CASE WHEN t.tier='other' THEN t.revenue_eur END),0) AS other_tier_revenue_eur
FROM months m
LEFT JOIN tiered t ON t.month = m.month
GROUP BY m.month
ORDER BY m.month NULLS LAST
