WITH disc_orders AS (
  SELECT o.id AS order_id, o.tenant_id AS tenant_id, o.user_id AS user_id, o.currency_code AS currency_code, o.placed_at AS placed_at,
         o.subtotal AS subtotal, o.discount_total AS discount_total, o.tax_total AS tax_total, o.shipping_total AS shipping_total, o.grand_total AS grand_total
  FROM order_discounts od
  JOIN discounts d ON d.id = od.discount_id AND d.tenant_id = od.tenant_id
  JOIN orders o ON o.id = od.order_id AND o.tenant_id = od.tenant_id
  WHERE d.name = 'Subscription delivery (prepaid)'
    AND o.status <> 'cancelled'
    AND o.placed_at >= TIMESTAMP '2025-01-01'
    AND o.placed_at < TIMESTAMP '2026-01-01'
),
rated AS (
  SELECT dso.*,
         er.rate AS rate,
         CAST({{divide_decimal(dso.subtotal, er.rate)}} AS NUMERIC(18,6)) AS subtotal_eur,
         CAST({{divide_decimal(dso.discount_total, er.rate)}} AS NUMERIC(18,6)) AS discount_total_eur,
         CAST({{divide_decimal(dso.tax_total, er.rate)}} AS NUMERIC(18,6)) AS tax_total_eur,
         CAST({{divide_decimal(dso.shipping_total, er.rate)}} AS NUMERIC(18,6)) AS shipping_total_eur,
         CAST({{divide_decimal(dso.grand_total, er.rate)}} AS NUMERIC(18,6)) AS grand_total_eur,
         CASE WHEN EXISTS (
           SELECT 1 FROM subscriptions s
           WHERE s.tenant_id = dso.tenant_id
             AND s.user_id = dso.user_id
             AND s.status IN ('trialing','active','past_due')
             AND s.started_at <= dso.placed_at
             AND (s.ended_at IS NULL OR s.ended_at >= dso.placed_at)
         ) THEN 1 ELSE 0 END AS has_active_sub
  FROM disc_orders dso
  JOIN exchange_rates er
    ON er.base_code = 'EUR'
   AND er.quote_code = dso.currency_code
   AND er.as_of = CAST(dso.placed_at AS date)
)
SELECT
  t.name AS tenant_name,
  COUNT(*) AS order_count,
  COUNT(DISTINCT r.user_id) AS distinct_customers,
  AVG(r.subtotal_eur) AS avg_subtotal_eur,
  AVG(r.discount_total_eur) AS avg_discount_total_eur,
  AVG(r.shipping_total_eur) AS avg_shipping_total_eur,
  AVG(r.tax_total_eur) AS avg_tax_total_eur,
  AVG(r.grand_total_eur) AS avg_grand_total_eur,
  {{divide_decimal(100.0 * SUM(CASE WHEN r.grand_total = 0 THEN 1 ELSE 0 END), COUNT(*))}} AS pct_zero_grand_total,
  {{divide_decimal(100.0 * SUM(r.has_active_sub), COUNT(*))}} AS pct_orders_with_active_subscription
FROM rated r
JOIN tenants t ON t.id = r.tenant_id
GROUP BY t.name
ORDER BY order_count DESC NULLS FIRST, tenant_name ASC NULLS LAST
