WITH tenants_list AS (
  SELECT id AS tenant_id, name AS tenant_name
  FROM tenants
  WHERE name IN ('Grind Collective','Honeycomb Larder','Kibblewick','Feather & Fin','Saffron & Sage','The Balm Room')
),
periods AS (
  SELECT '2023-H1' AS period, DATE '2023-01-01' AS start_date, DATE '2023-06-30' AS end_date UNION ALL
  SELECT '2023-H2', DATE '2023-07-01', DATE '2023-12-31' UNION ALL
  SELECT '2024-H1', DATE '2024-01-01', DATE '2024-06-30' UNION ALL
  SELECT '2024-H2', DATE '2024-07-01', DATE '2024-12-31' UNION ALL
  SELECT '2025-H1', DATE '2025-01-01', DATE '2025-06-30' UNION ALL
  SELECT '2025-H2', DATE '2025-07-01', DATE '2025-12-31'
),
base_grid AS (
  SELECT t.tenant_id AS tenant_id, t.tenant_name AS tenant_name, p.period AS period
  FROM tenants_list t CROSS JOIN periods p
),
orphan_order_discounts AS (
  SELECT
    o.tenant_id AS tenant_id,
    o.id AS order_id,
    o.user_id AS user_id,
    o.placed_at AS placed_at,
    od.amount AS discount_amount,
    od.currency_code AS currency_code,
    CASE WHEN EXTRACT(MONTH FROM o.placed_at) <= 6
         THEN CAST(EXTRACT(YEAR FROM o.placed_at) AS VARCHAR) || '-H1'
         ELSE CAST(EXTRACT(YEAR FROM o.placed_at) AS VARCHAR) || '-H2'
    END AS period
  FROM orders o
  JOIN order_discounts od ON od.order_id = o.id AND od.tenant_id = o.tenant_id
  JOIN discounts d ON d.id = od.discount_id AND d.tenant_id = o.tenant_id
  WHERE d.name = 'Subscription delivery (prepaid)'
    AND o.placed_at >= DATE '2023-01-01'
    AND o.placed_at < DATE '2026-01-01'
    AND o.status <> 'cancelled'
    AND o.tenant_id IN (SELECT tenant_id FROM tenants_list)
    AND NOT EXISTS (
      SELECT 1 FROM subscriptions s2
      WHERE s2.tenant_id = o.tenant_id AND s2.user_id = o.user_id
        AND s2.status IN ('active','trialing','past_due')
        AND s2.started_at <= o.placed_at
        AND (s2.ended_at IS NULL OR s2.ended_at >= o.placed_at)
    )
    AND EXISTS (
      SELECT 1 FROM (
        SELECT s3.status AS status, s3.user_id AS user_id,
               ROW_NUMBER() OVER (PARTITION BY s3.user_id ORDER BY s3.started_at DESC NULLS FIRST, s3.id DESC NULLS FIRST) AS rn
        FROM subscriptions s3
        WHERE s3.tenant_id = o.tenant_id AND s3.user_id = o.user_id
      ) latest
      WHERE latest.rn = 1 AND latest.status = 'canceled'
    )
),
agg AS (
  SELECT ood.tenant_id AS tenant_id, ood.period AS period,
         COUNT(DISTINCT ood.order_id) AS orphan_orders,
         COUNT(DISTINCT ood.user_id) AS distinct_customers,
         SUM(CAST({{divide_decimal(ood.discount_amount, COALESCE(er.rate,1))}} AS NUMERIC(18,6))) AS total_discount_eur
  FROM orphan_order_discounts ood
  LEFT JOIN exchange_rates er
    ON er.base_code = 'EUR'
   AND er.quote_code = ood.currency_code
   AND er.as_of = CAST(ood.placed_at AS DATE)
  GROUP BY ood.tenant_id, ood.period
)
SELECT
  g.tenant_name AS tenant_name,
  g.period AS half_year,
  COALESCE(a.orphan_orders,0) AS orphan_orders,
  COALESCE(a.distinct_customers,0) AS distinct_customers,
  COALESCE(a.total_discount_eur,0) AS total_discount_eur
FROM base_grid g
LEFT JOIN agg a ON a.tenant_id = g.tenant_id AND a.period = g.period
ORDER BY g.tenant_name NULLS LAST, g.period NULLS LAST, g.tenant_id NULLS LAST
