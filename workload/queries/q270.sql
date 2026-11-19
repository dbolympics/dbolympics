SELECT
  t.name AS merchant_name,
  t.industry AS industry,
  t.status AS status,
  CAST(MAX(o.placed_at) AS date) AS last_order_date,
  (DATE '2026-01-05' - CAST(MAX(o.placed_at) AS date)) AS days_since_last_order,
  COUNT(*) AS lifetime_orders,
  SUM(CAST({{divide_decimal(o.grand_total, er.rate)}} AS NUMERIC(18,6))) AS lifetime_revenue_eur
FROM tenants t
JOIN orders o
  ON o.tenant_id = t.id
 AND o.status <> 'cancelled'
 AND o.placed_at IS NOT NULL
JOIN exchange_rates er
  ON er.base_code = 'EUR'
 AND er.quote_code = o.currency_code
 AND er.as_of = CAST(o.placed_at AS date)
WHERE t.status <> 'churned'
GROUP BY t.id, t.name, t.industry, t.status
HAVING MAX(o.placed_at) < TIMESTAMP '2025-07-09'
   AND COUNT(*) >= 20
ORDER BY lifetime_revenue_eur DESC NULLS FIRST, t.id NULLS LAST
{{fetch_first(50)}}
