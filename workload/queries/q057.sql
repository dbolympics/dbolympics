SELECT segment, users_count, orders_count_2025, avg_orders_per_user, avg_order_value_eur, total_revenue_eur
FROM (
  SELECT
    CASE WHEN EXISTS (
      SELECT 1 FROM loyalty_accounts la
      WHERE la.user_id = o.user_id AND la.tenant_id = o.tenant_id
    ) THEN 'loyalty member' ELSE 'non-member' END AS segment,
    COUNT(DISTINCT o.user_id) AS users_count,
    COUNT(*) AS orders_count_2025,
    {{divide_decimal(CAST(COUNT(*) AS numeric(18,6)), COUNT(DISTINCT o.user_id))}} AS avg_orders_per_user,
    AVG(CAST({{divide_decimal(o.grand_total, COALESCE(er.rate, CASE WHEN o.currency_code = 'EUR' THEN 1 END))}} AS NUMERIC(18,6))) AS avg_order_value_eur,
    SUM(CAST({{divide_decimal(o.grand_total, COALESCE(er.rate, CASE WHEN o.currency_code = 'EUR' THEN 1 END))}} AS NUMERIC(18,6))) AS total_revenue_eur
  FROM orders o
  LEFT JOIN exchange_rates er
    ON er.base_code = 'EUR'
    AND er.quote_code = o.currency_code
    AND er.as_of = CAST(o.placed_at AS DATE)
  WHERE o.placed_at >= DATE '2025-01-01' AND o.placed_at < DATE '2026-01-01'
  GROUP BY CASE WHEN EXISTS (
      SELECT 1 FROM loyalty_accounts la
      WHERE la.user_id = o.user_id AND la.tenant_id = o.tenant_id
    ) THEN 'loyalty member' ELSE 'non-member' END
) seg
ORDER BY CASE WHEN segment = 'loyalty member' THEN 0 ELSE 1 END NULLS LAST
