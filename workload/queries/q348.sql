WITH months AS (
  SELECT DISTINCT month_start AS month
  FROM calendar_days
  WHERE calendar_date BETWEEN DATE '2023-01-01' AND DATE '2025-12-31'
),
tenant AS (
  SELECT id AS tenant_id FROM tenants WHERE name = 'Cragsley Outfitters'
),
reviews AS (
  SELECT CAST({{date_trunc('month', pr.created_at)}} AS date) AS month,
         count(*) AS review_count,
         avg(cast(pr.rating as numeric(18,6))) AS avg_rating,
         100.0 * count(*) FILTER (WHERE pr.rating <= 2) / NULLIF(count(*), 0) AS pct_1_2_star
  FROM product_reviews pr
  JOIN tenant t ON pr.tenant_id = t.tenant_id
  WHERE pr.is_approved = true
  GROUP BY 1
),
orders_agg AS (
  SELECT CAST({{date_trunc('month', o.placed_at)}} AS date) AS month,
         count(*) AS orders_count,
         sum(
           CASE WHEN o.currency_code = 'EUR' THEN o.grand_total
                ELSE CAST(o.grand_total / er.rate AS NUMERIC(18,6))
           END
         ) AS revenue_eur
  FROM orders o
  JOIN tenant t ON o.tenant_id = t.tenant_id
  LEFT JOIN exchange_rates er
    ON er.base_code = 'EUR'
   AND er.quote_code = o.currency_code
   AND er.as_of = CAST(o.placed_at AS date)
  WHERE o.status <> 'cancelled'
    AND o.placed_at IS NOT NULL
  GROUP BY 1
)
SELECT
  {{year_month(m.month)}} AS month_label,
  COALESCE(r.review_count, 0) AS review_count,
  r.avg_rating AS avg_rating,
  r.pct_1_2_star AS pct_1_2_star,
  COALESCE(oa.orders_count, 0) AS orders_count,
  COALESCE(oa.revenue_eur, 0) AS revenue_eur
FROM months m
LEFT JOIN reviews r ON r.month = m.month
LEFT JOIN orders_agg oa ON oa.month = m.month
ORDER BY m.month ASC NULLS LAST
