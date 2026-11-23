SELECT
  pop.status AS order_status,
  pop.order_count AS order_count,
  {{divide_decimal(pop.order_count * 100.0, SUM(pop.order_count) OVER ())}} AS pct_of_orders,
  pop.grand_total_eur AS orders_grand_total_eur,
  pop.orders_with_captured_payment_count AS orders_with_captured_payment_count,
  COALESCE(pay.captured_eur, 0) AS matched_captured_payment_eur,
  pop.grand_total_eur - COALESCE(pay.captured_eur, 0) AS gap_eur,
  {{divide_decimal((pop.grand_total_eur - COALESCE(pay.captured_eur, 0)), NULLIF(pop.grand_total_eur, 0))}} * 100 AS gap_pct
FROM (
  SELECT
    o.status AS status,
    COUNT(*) AS order_count,
    SUM(CAST({{divide_decimal(o.grand_total, er.rate)}} AS NUMERIC(18,6))) AS grand_total_eur,
    COUNT(CASE WHEN EXISTS (
      SELECT 1 FROM payments p WHERE p.order_id = o.id AND p.status = 'captured'
    ) THEN 1 END) AS orders_with_captured_payment_count
  FROM orders o
  JOIN exchange_rates er
    ON er.base_code = 'EUR'
   AND er.quote_code = o.currency_code
   AND er.as_of = CAST(o.placed_at AS date)
  WHERE o.placed_at >= DATE '2023-01-01'
    AND o.placed_at < DATE '2025-07-01'
  GROUP BY o.status
) pop
LEFT JOIN (
  SELECT
    o.status AS status,
    SUM(CAST({{divide_decimal(p.amount, er2.rate)}} AS NUMERIC(18,6))) AS captured_eur
  FROM payments p
  JOIN orders o ON o.id = p.order_id
  JOIN exchange_rates er2
    ON er2.base_code = 'EUR'
   AND er2.quote_code = p.currency_code
   AND er2.as_of = CAST(p.captured_at AS date)
  WHERE p.status = 'captured'
    AND o.placed_at >= DATE '2023-01-01'
    AND o.placed_at < DATE '2025-07-01'
  GROUP BY o.status
) pay ON pay.status = pop.status
ORDER BY orders_grand_total_eur DESC NULLS FIRST, pop.status NULLS LAST
