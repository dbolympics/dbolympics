WITH orders_base AS (
  SELECT
    o.id AS order_id,
    o.tenant_id AS tenant_id,
    o.user_id AS user_id,
    o.status AS status,
    o.currency_code AS currency_code,
    o.grand_total AS grand_total,
    COALESCE(o.placed_at, o.created_at) AS order_date
  FROM orders o
  JOIN users u ON u.id = o.user_id AND u.tenant_id = o.tenant_id
  WHERE u.is_staff = false
    AND COALESCE(o.placed_at, o.created_at) >= DATE '2023-01-01'
    AND COALESCE(o.placed_at, o.created_at) < DATE '2026-01-01'
),
orders_enriched AS (
  SELECT
    ob.*,
    CASE WHEN ob.currency_code = 'EUR' THEN CAST(ob.grand_total AS NUMERIC(18,6))
         ELSE CAST({{divide_decimal(ob.grand_total, er.rate)}} AS NUMERIC(18,6)) END AS eur_amount,
    EXISTS (SELECT 1 FROM payments p WHERE p.order_id = ob.order_id AND p.amount_refunded > 0) AS has_refund,
    EXISTS (SELECT 1 FROM order_returns r WHERE r.order_id = ob.order_id) AS has_return
  FROM orders_base ob
  LEFT JOIN exchange_rates er
    ON er.base_code = 'EUR' AND er.quote_code = ob.currency_code AND er.as_of = CAST(ob.order_date AS DATE)
),
customer_agg AS (
  SELECT
    user_id,
    COUNT(*) AS total_orders,
    COUNT(*) FILTER (WHERE status <> 'cancelled') AS noncancelled_orders,
    SUM(eur_amount) FILTER (WHERE status <> 'cancelled') AS noncancelled_revenue,
    MIN(order_date) AS first_order_date,
    MAX(order_date) AS last_order_date,
    COUNT(*) FILTER (WHERE has_refund OR has_return) AS refunded_orders
  FROM orders_enriched
  GROUP BY user_id
),
segmented AS (
  SELECT
    ca.*,
    CASE WHEN EXISTS (SELECT 1 FROM loyalty_accounts la WHERE la.user_id = ca.user_id)
         THEN 'loyalty member' ELSE 'non-member' END AS segment
  FROM customer_agg ca
)
SELECT
  segment,
  COUNT(*) AS customer_count,
  AVG(CAST(total_orders AS NUMERIC(18,6))) AS avg_lifetime_orders,
  ({{divide_decimal(SUM(noncancelled_revenue), NULLIF(COUNT(*),0))}}) AS avg_lifetime_revenue_eur,
  ({{divide_decimal(SUM(noncancelled_revenue), NULLIF(SUM(noncancelled_orders),0))}}) AS avg_order_value_eur,
  (AVG({{divide_decimal({{seconds_between(first_order_date, last_order_date)}}, 86400.0)}})) AS avg_tenure_days,
  ({{divide_decimal(100.0 * COUNT(*) FILTER (WHERE total_orders >= 2), NULLIF(COUNT(*),0))}}) AS repeat_purchase_rate_pct,
  ({{divide_decimal(100.0 * SUM(refunded_orders), NULLIF(SUM(total_orders),0))}}) AS refund_rate_pct
FROM segmented
GROUP BY segment
ORDER BY CASE WHEN segment = 'loyalty member' THEN 0 ELSE 1 END NULLS LAST, segment NULLS LAST
