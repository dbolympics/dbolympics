SELECT
  t0.name AS merchant_name,
  t0.industry AS industry,
  t0.employee_count AS employee_count,
  COALESCE(t1.orders_last90, 0) AS orders_last_90_days,
  COALESCE(t1.revenue_last90_eur, 0) AS gross_revenue_eur_last_90_days,
  COALESCE(t2.orders_prior90, 0) AS orders_prior_90_days,
  COALESCE(t2.revenue_prior90_eur, 0) AS gross_revenue_eur_prior_90_days,
  CASE WHEN COALESCE(t2.revenue_prior90_eur,0) = 0 THEN NULL
       ELSE ({{divide_decimal((COALESCE(t1.revenue_last90_eur,0) - t2.revenue_prior90_eur), t2.revenue_prior90_eur)}}) * 100
  END AS revenue_growth_pct,
  CASE WHEN COALESCE(t2.orders_prior90,0) = 0 THEN NULL
       ELSE {{divide_decimal(CAST(COALESCE(t1.orders_last90,0) - t2.orders_prior90 AS NUMERIC(18,6)) * 100, t2.orders_prior90)}}
  END AS order_growth_pct
FROM tenants t0
LEFT JOIN (
  SELECT o1.tenant_id AS tenant_id,
         COUNT(*) AS orders_last90,
         SUM(CAST({{divide_decimal(o1.grand_total, er1.rate)}} AS NUMERIC(18,6))) AS revenue_last90_eur
  FROM orders o1
  JOIN exchange_rates er1
    ON er1.base_code = 'EUR'
   AND er1.quote_code = o1.currency_code
   AND er1.as_of = CAST(o1.placed_at AS date)
  WHERE o1.status <> 'cancelled'
    AND o1.placed_at >= TIMESTAMP '2025-10-03 00:00:00'
    AND o1.placed_at <  TIMESTAMP '2026-01-01 00:00:00'
  GROUP BY o1.tenant_id
) t1 ON t1.tenant_id = t0.id
LEFT JOIN (
  SELECT o2.tenant_id AS tenant_id,
         COUNT(*) AS orders_prior90,
         SUM(CAST({{divide_decimal(o2.grand_total, er2.rate)}} AS NUMERIC(18,6))) AS revenue_prior90_eur
  FROM orders o2
  JOIN exchange_rates er2
    ON er2.base_code = 'EUR'
   AND er2.quote_code = o2.currency_code
   AND er2.as_of = CAST(o2.placed_at AS date)
  WHERE o2.status <> 'cancelled'
    AND o2.placed_at >= TIMESTAMP '2025-07-05 00:00:00'
    AND o2.placed_at <  TIMESTAMP '2025-10-03 00:00:00'
  GROUP BY o2.tenant_id
) t2 ON t2.tenant_id = t0.id
ORDER BY gross_revenue_eur_last_90_days DESC NULLS FIRST, t0.id ASC NULLS LAST
{{fetch_first(50)}}
