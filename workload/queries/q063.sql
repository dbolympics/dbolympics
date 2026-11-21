SELECT t0.id AS tenant_id, t0.name AS merchant_name, t0.industry AS industry,
  COALESCE(t1.revenue_eur_a, 0) AS revenue_eur_2025,
  COALESCE(t2.revenue_eur_b, 0) AS revenue_eur_2024,
  CASE WHEN COALESCE(t2.revenue_eur_b, 0) = 0 THEN NULL
       ELSE ({{divide_decimal((COALESCE(t1.revenue_eur_a, 0) - t2.revenue_eur_b), t2.revenue_eur_b)}}) * 100
  END AS revenue_yoy_growth_pct,
  COALESCE(t3.orders_a, 0) AS orders_2025,
  COALESCE(t4.orders_b, 0) AS orders_2024,
  CASE WHEN COALESCE(t4.orders_b, 0) = 0 THEN NULL
       ELSE ({{divide_decimal(CAST((COALESCE(t3.orders_a, 0) - t4.orders_b) AS numeric(18,6)), t4.orders_b)}}) * 100
  END AS order_yoy_growth_pct
FROM tenants t0
LEFT JOIN (
  SELECT o.tenant_id AS tenant_id, SUM(CAST({{divide_decimal(o.grand_total, er.rate)}} AS NUMERIC(18,6))) AS revenue_eur_a
  FROM orders o
  JOIN exchange_rates er
    ON er.base_code = 'EUR'
   AND er.quote_code = o.currency_code
   AND er.as_of = CAST(o.placed_at AS DATE)
  WHERE o.placed_at >= DATE '2025-10-01'
    AND o.placed_at < DATE '2026-01-01'
    AND o.status <> 'cancelled'
  GROUP BY o.tenant_id
) t1 ON t1.tenant_id = t0.id
LEFT JOIN (
  SELECT o.tenant_id AS tenant_id, SUM(CAST({{divide_decimal(o.grand_total, er.rate)}} AS NUMERIC(18,6))) AS revenue_eur_b
  FROM orders o
  JOIN exchange_rates er
    ON er.base_code = 'EUR'
   AND er.quote_code = o.currency_code
   AND er.as_of = CAST(o.placed_at AS DATE)
  WHERE o.placed_at >= DATE '2024-10-01'
    AND o.placed_at < DATE '2025-01-01'
    AND o.status <> 'cancelled'
  GROUP BY o.tenant_id
) t2 ON t2.tenant_id = t0.id
LEFT JOIN (
  SELECT o.tenant_id AS tenant_id, COUNT(*) AS orders_a
  FROM orders o
  WHERE o.placed_at >= DATE '2025-10-01'
    AND o.placed_at < DATE '2026-01-01'
    AND o.status <> 'cancelled'
  GROUP BY o.tenant_id
) t3 ON t3.tenant_id = t0.id
LEFT JOIN (
  SELECT o.tenant_id AS tenant_id, COUNT(*) AS orders_b
  FROM orders o
  WHERE o.placed_at >= DATE '2024-10-01'
    AND o.placed_at < DATE '2025-01-01'
    AND o.status <> 'cancelled'
  GROUP BY o.tenant_id
) t4 ON t4.tenant_id = t0.id
ORDER BY COALESCE(t1.revenue_eur_a, 0) DESC NULLS FIRST, t0.id ASC NULLS LAST
{{fetch_first(50)}}
