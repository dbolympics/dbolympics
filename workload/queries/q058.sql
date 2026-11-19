SELECT t.industry AS industry,
  COUNT(DISTINCT CASE WHEN dla.user_id IS NOT NULL THEN o.user_id END) AS members_count,
  COUNT(DISTINCT CASE WHEN dla.user_id IS NULL THEN o.user_id END) AS nonmembers_count,
  {{divide_decimal(CAST(COUNT(CASE WHEN dla.user_id IS NOT NULL THEN o.id END) AS numeric(18,6)), NULLIF(COUNT(DISTINCT CASE WHEN dla.user_id IS NOT NULL THEN o.user_id END), 0))}} AS avg_orders_per_member,
  {{divide_decimal(CAST(COUNT(CASE WHEN dla.user_id IS NULL THEN o.id END) AS numeric(18,6)), NULLIF(COUNT(DISTINCT CASE WHEN dla.user_id IS NULL THEN o.user_id END), 0))}} AS avg_orders_per_nonmember,
  AVG(CASE WHEN dla.user_id IS NOT NULL
           THEN {{divide_decimal(o.grand_total, (CASE WHEN o.currency_code = 'EUR' THEN 1 ELSE er.rate END))}}
      END) AS avg_order_value_member_eur,
  AVG(CASE WHEN dla.user_id IS NULL
           THEN {{divide_decimal(o.grand_total, (CASE WHEN o.currency_code = 'EUR' THEN 1 ELSE er.rate END))}}
      END) AS avg_order_value_nonmember_eur
FROM orders o
JOIN tenants t ON t.id = o.tenant_id
LEFT JOIN (SELECT DISTINCT tenant_id, user_id FROM loyalty_accounts) dla
  ON dla.tenant_id = o.tenant_id AND dla.user_id = o.user_id
LEFT JOIN exchange_rates er
  ON er.base_code = 'EUR' AND er.quote_code = o.currency_code AND er.as_of = CAST(o.placed_at AS DATE)
WHERE o.placed_at >= TIMESTAMP '2025-01-01' AND o.placed_at < TIMESTAMP '2026-01-01'
  AND t.industry IN (
    SELECT DISTINCT t2.industry AS industry
    FROM tenants t2
    JOIN loyalty_programs lp ON lp.tenant_id = t2.id
    WHERE lp.is_active = true
  )
GROUP BY t.industry
ORDER BY t.industry NULLS LAST
