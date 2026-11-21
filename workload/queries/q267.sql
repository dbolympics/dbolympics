SELECT
  t.id AS tenant_id,
  t.name AS tenant_name,
  t.industry AS industry,
  t.default_currency_code AS default_currency_code,
  COUNT(DISTINCT m.user_id) AS members_count,
  COUNT(o.id) AS member_orders_count_2025,
  SUM(CASE WHEN o.currency_code = t.default_currency_code THEN o.grand_total ELSE 0 END) AS member_revenue_local_sum,
  SUM(CASE WHEN er.rate IS NOT NULL THEN CAST({{divide_decimal(o.grand_total, er.rate)}} AS NUMERIC(18,6)) ELSE 0 END) AS member_revenue_eur_converted,
  COUNT(CASE WHEN er.rate IS NULL THEN 1 END) AS orders_missing_exchange_rate_count,
  CASE WHEN COUNT(DISTINCT o.currency_code) > 1 THEN true ELSE false END AS has_mixed_currency_orders
FROM tenants t
JOIN (
  SELECT DISTINCT la.tenant_id AS tenant_id, la.user_id AS user_id
  FROM loyalty_accounts la
  JOIN orders o2 ON o2.user_id = la.user_id AND o2.tenant_id = la.tenant_id
  WHERE o2.placed_at >= DATE '2025-01-01' AND o2.placed_at < DATE '2026-01-01'
) m ON m.tenant_id = t.id
JOIN orders o ON o.tenant_id = m.tenant_id AND o.user_id = m.user_id
  AND o.placed_at >= DATE '2025-01-01' AND o.placed_at < DATE '2026-01-01'
LEFT JOIN exchange_rates er ON er.base_code = 'EUR' AND er.quote_code = o.currency_code AND er.as_of = CAST(o.placed_at AS DATE)
WHERE t.industry IN ('Books & Stationery','Food & Coffee','Pet Supplies')
GROUP BY t.id, t.name, t.industry, t.default_currency_code
ORDER BY t.name ASC NULLS LAST, t.id ASC NULLS LAST
