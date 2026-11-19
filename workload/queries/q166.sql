WITH loyalty_members AS (
  SELECT DISTINCT user_id
  FROM loyalty_accounts
),
scoped_orders AS (
  SELECT o.id AS id, o.tenant_id AS tenant_id, o.user_id AS user_id, o.status AS status, o.currency_code AS currency_code, o.grand_total AS grand_total, o.placed_at AS placed_at
  FROM orders o
  JOIN loyalty_members lm ON lm.user_id = o.user_id
  WHERE o.placed_at >= DATE '2023-01-01' AND o.placed_at < DATE '2026-01-01'
),
redeem_agg AS (
  SELECT order_id, SUM(ABS(points)) AS points_redeemed, COUNT(*) AS redeem_tx_count
  FROM loyalty_transactions
  WHERE direction <> 'earn' AND order_id IS NOT NULL
  GROUP BY order_id
),
refund_payment_orders AS (
  SELECT DISTINCT order_id
  FROM payments
  WHERE order_id IS NOT NULL AND amount_refunded > 0
),
refund_return_orders AS (
  SELECT DISTINCT order_id
  FROM order_returns
),
classified AS (
  SELECT
    so.id AS id,
    so.tenant_id AS tenant_id,
    so.user_id AS user_id,
    so.status AS status,
    so.currency_code AS currency_code,
    so.grand_total AS grand_total,
    so.placed_at AS placed_at,
    CASE WHEN ra.order_id IS NOT NULL THEN 'points redeemed on this order' ELSE 'no points redeemed on this order' END AS order_type,
    COALESCE(ra.points_redeemed, 0) AS points_redeemed,
    CASE WHEN rpo.order_id IS NOT NULL OR rro.order_id IS NOT NULL THEN 1 ELSE 0 END AS is_refunded
  FROM scoped_orders so
  LEFT JOIN redeem_agg ra ON ra.order_id = so.id
  LEFT JOIN refund_payment_orders rpo ON rpo.order_id = so.id
  LEFT JOIN refund_return_orders rro ON rro.order_id = so.id
),
valued AS (
  SELECT
    c.*,
    CASE WHEN c.status <> 'cancelled' THEN CAST({{divide_decimal(c.grand_total, er.rate)}} AS NUMERIC(18,6)) ELSE NULL END AS grand_total_eur
  FROM classified c
  LEFT JOIN exchange_rates er
    ON er.base_code = 'EUR'
   AND er.quote_code = c.currency_code
   AND er.as_of = CAST(c.placed_at AS DATE)
)
SELECT
  order_type,
  COUNT(*) AS order_count,
  COUNT(DISTINCT user_id) AS distinct_customers,
  {{divide_decimal(100.0 * SUM(is_refunded), COUNT(*))}} AS refund_rate_pct,
  AVG(grand_total_eur) AS avg_order_value_eur,
  AVG(points_redeemed) AS avg_points_redeemed_per_order
FROM valued
GROUP BY order_type
ORDER BY CASE WHEN order_type = 'points redeemed on this order' THEN 0 ELSE 1 END NULLS LAST, order_type NULLS LAST
