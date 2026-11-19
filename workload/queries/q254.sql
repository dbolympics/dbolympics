WITH qualifying_tenants AS (
  SELECT tenant_id
  FROM tickets
  WHERE created_at >= DATE '2025-01-01' AND created_at < DATE '2026-01-01'
  GROUP BY tenant_id
  HAVING COUNT(*) >= 20
),
order_eur AS (
  SELECT
    o.tenant_id AS tenant_id,
    o.id AS order_id,
    CASE
      WHEN o.currency_code = 'EUR' THEN o.grand_total
      ELSE CAST({{divide_decimal(o.grand_total, er.rate)}} AS NUMERIC(18,6))
    END AS grand_total_eur
  FROM orders o
  LEFT JOIN exchange_rates er
    ON er.base_code = 'EUR'
   AND er.quote_code = o.currency_code
   AND er.as_of = CAST(o.placed_at AS DATE)
  WHERE o.placed_at >= DATE '2025-01-01' AND o.placed_at < DATE '2026-01-01'
)
SELECT
  t.name AS merchant_name,
  t.industry AS industry,
  t.employee_count AS employee_count,
  COUNT(oe.order_id) AS orders_placed_2025,
  AVG(oe.grand_total_eur) AS avg_order_value_eur_2025
FROM qualifying_tenants qt
JOIN tenants t ON t.id = qt.tenant_id
LEFT JOIN order_eur oe ON oe.tenant_id = t.id
GROUP BY t.name, t.industry, t.employee_count
ORDER BY orders_placed_2025 DESC NULLS FIRST, merchant_name ASC NULLS LAST, t.industry ASC NULLS LAST, t.employee_count ASC NULLS LAST
