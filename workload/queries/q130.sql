WITH order_rev AS (
  SELECT
    o.tenant_id AS tenant_id,
    COUNT(*) AS total_orders_2025,
    SUM(CAST({{divide_decimal(o.grand_total, er.rate)}} AS NUMERIC(18,6))) AS total_revenue_eur_2025
  FROM orders o
  JOIN exchange_rates er
    ON er.base_code = 'EUR'
   AND er.quote_code = o.currency_code
   AND er.as_of = CAST(o.placed_at AS DATE)
  WHERE o.placed_at >= TIMESTAMP '2025-01-01'
    AND o.placed_at < TIMESTAMP '2026-01-01'
  GROUP BY o.tenant_id
),
affected AS (
  SELECT DISTINCT jr.tenant_id AS tenant_id
  FROM job_runs jr
  JOIN jobs j ON j.id = jr.job_id
  WHERE j.handler = 'carts.remind'
    AND jr.status = 'failed'
    AND jr.queued_at >= TIMESTAMP '2025-11-01'
    AND jr.queued_at < TIMESTAMP '2025-12-01'
),
ranked AS (
  SELECT
    t.id AS tenant_id,
    t.name AS tenant_name,
    COALESCE(orv.total_orders_2025, 0) AS total_orders_2025,
    COALESCE(orv.total_revenue_eur_2025, 0) AS total_revenue_eur_2025,
    DENSE_RANK() OVER (ORDER BY COALESCE(orv.total_revenue_eur_2025, 0) DESC NULLS FIRST) AS revenue_rank,
    CASE WHEN a.tenant_id IS NOT NULL THEN 'Yes' ELSE 'No' END AS was_affected_by_nov_carts_remind_failure
  FROM tenants t
  LEFT JOIN order_rev orv ON orv.tenant_id = t.id
  LEFT JOIN affected a ON a.tenant_id = t.id
)
SELECT
  tenant_name,
  total_orders_2025,
  total_revenue_eur_2025 AS total_revenue_eur_2025,
  revenue_rank,
  was_affected_by_nov_carts_remind_failure
FROM ranked
ORDER BY was_affected_by_nov_carts_remind_failure DESC NULLS FIRST, revenue_rank ASC NULLS LAST, tenant_name ASC NULLS LAST, tenant_id NULLS LAST
{{fetch_first(30)}}
