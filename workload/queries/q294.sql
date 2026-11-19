SELECT
  CAST(c.created_at AS date) AS cart_date,
  COUNT(*) AS carts_created,
  {{divide_decimal(100.0 * SUM(CASE WHEN c.status = 'converted' THEN 1 ELSE 0 END), COUNT(*))}} AS overall_conversion_pct,
  {{divide_decimal(100.0 * SUM(CASE WHEN c.status = 'converted' AND c.converted_at IS NOT NULL AND c.converted_at <= c.created_at + INTERVAL '1 hour' THEN 1 ELSE 0 END), COUNT(*))}} AS pct_converted_within_1_hour
FROM carts c
JOIN tenants t ON t.id = c.tenant_id
WHERE t.name = 'Cragsley Outfitters'
  AND c.created_at >= DATE '2025-11-17'
  AND c.created_at < DATE '2025-12-02'
GROUP BY CAST(c.created_at AS date)
ORDER BY cart_date ASC NULLS LAST
