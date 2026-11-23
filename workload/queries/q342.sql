SELECT
  CAST(EXTRACT(HOUR FROM o.placed_at) AS int) AS hour,
  COUNT(*) AS total_orders_placed,
  COUNT(DISTINCT o.tenant_id) AS distinct_tenants_with_orders,
  SUM(CAST({{divide_decimal(o.grand_total, er.rate)}} AS NUMERIC(18,6))) AS total_revenue_eur
FROM orders o
JOIN exchange_rates er
  ON er.base_code = 'EUR'
  AND er.quote_code = o.currency_code
  AND er.as_of = DATE '2025-11-28'
WHERE o.placed_at >= TIMESTAMP '2025-11-28 00:00:00'
  AND o.placed_at < TIMESTAMP '2025-11-29 00:00:00'
GROUP BY EXTRACT(HOUR FROM o.placed_at)
ORDER BY hour ASC NULLS LAST
