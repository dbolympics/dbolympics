WITH loyalty_industries AS (
  SELECT DISTINCT t.industry AS industry
  FROM loyalty_programs lp
  JOIN tenants t ON t.id = lp.tenant_id
  WHERE lp.is_active = true AND t.industry IS NOT NULL
),
orders_2025 AS (
  SELECT
    o.id AS order_id,
    o.user_id AS user_id,
    o.tenant_id AS tenant_id,
    t.industry AS industry,
    o.placed_at AS placed_at,
    o.grand_total AS grand_total,
    o.currency_code AS currency_code,
    CASE WHEN EXISTS (
      SELECT 1 FROM loyalty_accounts la
      WHERE la.user_id = o.user_id AND la.tenant_id = o.tenant_id
    ) THEN 'loyalty member' ELSE 'non-member' END AS segment
  FROM orders o
  JOIN tenants t ON t.id = o.tenant_id
  WHERE o.placed_at >= DATE '2025-01-01' AND o.placed_at < DATE '2026-01-01'
    AND t.industry IN (SELECT industry FROM loyalty_industries)
),
orders_eur AS (
  SELECT oe.*,
    CASE WHEN oe.currency_code = 'EUR' THEN CAST(oe.grand_total AS NUMERIC(18,6))
         ELSE CAST({{divide_decimal(oe.grand_total, er.rate)}} AS NUMERIC(18,6))
    END AS grand_total_eur
  FROM orders_2025 oe
  LEFT JOIN exchange_rates er
    ON er.base_code = 'EUR' AND er.quote_code = oe.currency_code AND er.as_of = CAST(oe.placed_at AS DATE)
),
user_stats AS (
  SELECT industry, segment, user_id,
    COUNT(*) AS order_count,
    COUNT(DISTINCT CAST(placed_at AS DATE)) AS distinct_order_days
  FROM orders_eur
  GROUP BY industry, segment, user_id
),
agg_users AS (
  SELECT industry, segment,
    COUNT(*) AS users_count,
    COUNT(*) FILTER (WHERE distinct_order_days >= 2) AS repeat_users,
    AVG(CAST(order_count AS NUMERIC(18,6))) AS avg_orders_per_user
  FROM user_stats
  GROUP BY industry, segment
),
agg_orders AS (
  SELECT industry, segment, AVG(grand_total_eur) AS avg_order_value_eur
  FROM orders_eur
  GROUP BY industry, segment
)
SELECT
  au.industry AS industry,
  au.segment AS segment,
  au.users_count AS users_count,
  {{divide_decimal(100.0 * au.repeat_users, NULLIF(au.users_count,0))}} AS repeat_rate_pct,
  au.avg_orders_per_user AS avg_orders_per_user,
  ao.avg_order_value_eur AS avg_order_value_eur
FROM agg_users au
JOIN agg_orders ao ON ao.industry = au.industry AND ao.segment = au.segment
ORDER BY au.industry ASC NULLS LAST, au.segment ASC NULLS LAST
