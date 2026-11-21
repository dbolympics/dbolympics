WITH user_orders AS (
  SELECT o.id AS order_id, o.user_id AS user_id, o.tenant_id AS tenant_id, o.placed_at AS placed_at
  FROM orders o
  JOIN users u ON u.id = o.user_id AND u.tenant_id = o.tenant_id
  WHERE u.is_staff = false
    AND o.placed_at >= TIMESTAMP '2023-01-01'
    AND o.placed_at < TIMESTAMP '2026-01-01'
),
user_stats AS (
  SELECT user_id, tenant_id, COUNT(*) AS order_count, MIN(placed_at) AS first_order, MAX(placed_at) AS last_order
  FROM user_orders
  GROUP BY user_id, tenant_id
  HAVING COUNT(*) >= 2
),
loyalty_acct AS (
  SELECT DISTINCT tenant_id, user_id FROM loyalty_accounts
),
loyalty_burn AS (
  SELECT DISTINCT tenant_id, user_id FROM loyalty_transactions WHERE direction = 'burn'
),
user_group AS (
  SELECT us.user_id AS user_id, us.tenant_id AS tenant_id, us.first_order AS first_order, us.last_order AS last_order,
    {{timestamp_midpoint(us.first_order, us.last_order)}} AS midpoint,
    CASE
      WHEN la.user_id IS NULL THEN 'non-member'
      WHEN lb.user_id IS NOT NULL THEN 'ever-redeemed member'
      ELSE 'never-redeemed member'
    END AS customer_group
  FROM user_stats us
  LEFT JOIN loyalty_acct la ON la.tenant_id = us.tenant_id AND la.user_id = us.user_id
  LEFT JOIN loyalty_burn lb ON lb.tenant_id = us.tenant_id AND lb.user_id = us.user_id
),
order_period AS (
  SELECT uo.order_id AS order_id, uo.user_id AS user_id, uo.tenant_id AS tenant_id, uo.placed_at AS placed_at,
    ug.customer_group AS customer_group,
    CASE WHEN uo.placed_at < ug.midpoint THEN 'first half' ELSE 'second half' END AS period
  FROM user_orders uo
  JOIN user_group ug ON ug.user_id = uo.user_id AND ug.tenant_id = uo.tenant_id
),
payment_refund AS (
  SELECT order_id, tenant_id, MAX(CASE WHEN amount_refunded > 0 THEN 1 ELSE 0 END) AS has_refund
  FROM payments
  WHERE order_id IS NOT NULL
  GROUP BY order_id, tenant_id
),
return_flag AS (
  SELECT DISTINCT order_id, tenant_id, 1 AS has_return
  FROM order_returns
),
order_refund AS (
  SELECT op.order_id AS order_id, op.user_id AS user_id, op.tenant_id AS tenant_id, op.customer_group AS customer_group, op.period AS period,
    CASE WHEN COALESCE(pr.has_refund,0) = 1 OR rf.has_return = 1 THEN 1 ELSE 0 END AS is_refunded
  FROM order_period op
  LEFT JOIN payment_refund pr ON pr.order_id = op.order_id AND pr.tenant_id = op.tenant_id
  LEFT JOIN return_flag rf ON rf.order_id = op.order_id AND rf.tenant_id = op.tenant_id
),
customer_period AS (
  SELECT customer_group, period, user_id, tenant_id,
    COUNT(*) AS order_count,
    SUM(is_refunded) AS refund_count
  FROM order_refund
  GROUP BY customer_group, period, user_id, tenant_id
),
customer_period_exposed AS (
  SELECT cp.customer_group AS customer_group, cp.period AS period, cp.user_id AS user_id, cp.tenant_id AS tenant_id, cp.order_count AS order_count, cp.refund_count AS refund_count,
    CASE WHEN cp.period = 'first half'
      THEN GREATEST(1, {{date_diff_days(ug.first_order, ug.midpoint)}})
      ELSE GREATEST(1, {{date_diff_days(ug.midpoint, ug.last_order)}})
    END AS exposed_days
  FROM customer_period cp
  JOIN user_group ug ON ug.user_id = cp.user_id AND ug.tenant_id = cp.tenant_id
)
SELECT
  customer_group AS "group",
  period,
  COUNT(*) AS customer_count,
  SUM(order_count) AS total_orders,
  SUM(order_count) / ({{divide_decimal(SUM(exposed_days), 365.0)}}) AS orders_per_customer_per_year,
  {{divide_decimal(100.0 * SUM(refund_count), SUM(order_count))}} AS refund_rate_pct
FROM customer_period_exposed
GROUP BY customer_group, period
ORDER BY
  CASE customer_group WHEN 'non-member' THEN 1 WHEN 'never-redeemed member' THEN 2 WHEN 'ever-redeemed member' THEN 3 END NULLS LAST,
  CASE period WHEN 'first half' THEN 1 ELSE 2 END NULLS LAST
