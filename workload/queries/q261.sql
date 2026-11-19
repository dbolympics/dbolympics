WITH order_amounts AS (
  SELECT
    o.id AS order_id,
    o.tenant_id AS tenant_id,
    o.user_id AS user_id,
    CAST({{divide_decimal(o.grand_total, er.rate)}} AS NUMERIC(18,6)) AS grand_total_eur
  FROM orders o
  JOIN exchange_rates er
    ON er.base_code = 'EUR'
    AND er.quote_code = o.currency_code
    AND er.as_of = CAST(o.placed_at AS date)
  WHERE o.placed_at >= DATE '2025-01-01'
    AND o.placed_at < DATE '2026-01-01'
),
flagged AS (
  SELECT
    oa.order_id AS order_id,
    oa.tenant_id AS tenant_id,
    oa.user_id AS user_id,
    oa.grand_total_eur AS grand_total_eur,
    t.industry AS industry,
    CASE WHEN EXISTS (
      SELECT 1 FROM referrals r
      WHERE r.tenant_id = oa.tenant_id AND r.referrer_user_id = oa.user_id
    ) THEN 'referrer' ELSE 'non-referrer' END AS segment
  FROM order_amounts oa
  JOIN tenants t ON t.id = oa.tenant_id
  WHERE t.industry IS NOT NULL
),
user_level AS (
  SELECT industry, segment, tenant_id, user_id, COUNT(*) AS orders_count
  FROM flagged
  GROUP BY industry, segment, tenant_id, user_id
),
industry_user_totals AS (
  SELECT industry, COUNT(*) AS total_users
  FROM (SELECT DISTINCT industry, tenant_id, user_id FROM flagged) x
  GROUP BY industry
),
segment_agg AS (
  SELECT industry, segment,
    COUNT(*) AS users_count,
    AVG(CAST(orders_count AS NUMERIC(18,6))) AS avg_orders_per_user
  FROM user_level
  GROUP BY industry, segment
),
order_level_agg AS (
  SELECT industry, segment, AVG(grand_total_eur) AS avg_order_value_eur
  FROM flagged
  GROUP BY industry, segment
)
SELECT
  s.industry AS industry,
  s.segment AS segment,
  s.users_count AS users_count,
  {{divide_decimal(100.0 * s.users_count, t.total_users)}} AS share_of_industry_users_pct,
  s.avg_orders_per_user AS avg_orders_per_user,
  o.avg_order_value_eur AS avg_order_value_eur
FROM segment_agg s
JOIN industry_user_totals t ON t.industry = s.industry
JOIN order_level_agg o ON o.industry = s.industry AND o.segment = s.segment
ORDER BY s.industry ASC NULLS LAST, CASE WHEN s.segment = 'referrer' THEN 0 ELSE 1 END NULLS LAST
