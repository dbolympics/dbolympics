WITH eligible_users AS (
  SELECT DISTINCT u.id AS user_id, u.tenant_id AS tenant_id, u.created_at AS created_at
  FROM users u
  JOIN orders o ON o.user_id = u.id AND o.tenant_id = u.tenant_id
  WHERE u.is_staff = false
    AND o.placed_at >= TIMESTAMP '2023-01-01 00:00:00'
    AND o.placed_at < TIMESTAMP '2026-01-01 00:00:00'
),
tenure AS (
  SELECT
    user_id, tenant_id,
    CASE
      WHEN created_at > TIMESTAMP '2026-01-01 00:00:00' - INTERVAL '6 months' THEN 'under 6 months'
      WHEN created_at > TIMESTAMP '2026-01-01 00:00:00' - INTERVAL '12 months' THEN '6 to 12 months'
      WHEN created_at > TIMESTAMP '2026-01-01 00:00:00' - INTERVAL '24 months' THEN '12 to 24 months'
      ELSE 'over 24 months'
    END AS tenure_band
  FROM eligible_users
),
loyalty_member AS (
  SELECT DISTINCT user_id, tenant_id FROM loyalty_accounts
),
loyalty_redeemed AS (
  SELECT DISTINCT user_id, tenant_id FROM loyalty_transactions WHERE direction = 'burn'
),
membership AS (
  SELECT
    eu.user_id AS user_id, eu.tenant_id AS tenant_id,
    CASE
      WHEN lm.user_id IS NULL THEN 'non-member'
      WHEN lr.user_id IS NOT NULL THEN 'ever-redeemed member'
      ELSE 'never-redeemed member'
    END AS customer_group
  FROM eligible_users eu
  LEFT JOIN loyalty_member lm ON lm.user_id = eu.user_id AND lm.tenant_id = eu.tenant_id
  LEFT JOIN loyalty_redeemed lr ON lr.user_id = eu.user_id AND lr.tenant_id = eu.tenant_id
),
order_refund_flag AS (
  SELECT
    o.id AS order_id,
    CASE
      WHEN EXISTS (SELECT 1 FROM payments p WHERE p.order_id = o.id AND p.amount_refunded > 0)
        OR EXISTS (SELECT 1 FROM order_returns r WHERE r.order_id = o.id)
      THEN 1 ELSE 0
    END AS is_refunded
  FROM orders o
),
order_eur AS (
  SELECT
    o.id AS order_id,
    o.user_id AS user_id,
    o.tenant_id AS tenant_id,
    o.status AS status,
    CASE WHEN o.status <> 'cancelled' THEN CAST({{divide_decimal(o.grand_total, er.rate)}} AS NUMERIC(18,6)) ELSE NULL END AS revenue_eur
  FROM orders o
  LEFT JOIN exchange_rates er
    ON er.base_code = 'EUR'
    AND er.quote_code = o.currency_code
    AND er.as_of = CAST(COALESCE(o.placed_at, o.created_at) AS date)
),
customer_orders AS (
  SELECT
    eu.user_id AS user_id,
    eu.tenant_id AS tenant_id,
    COUNT(o.id) AS lifetime_orders,
    SUM(CASE WHEN o.status <> 'cancelled' THEN oe.revenue_eur ELSE 0 END) AS lifetime_revenue_eur,
    SUM(CASE WHEN o.status <> 'cancelled' THEN 1 ELSE 0 END) AS non_cancelled_order_count,
    SUM(orf.is_refunded) AS refunded_order_count
  FROM eligible_users eu
  JOIN orders o ON o.user_id = eu.user_id AND o.tenant_id = eu.tenant_id
  JOIN order_eur oe ON oe.order_id = o.id
  JOIN order_refund_flag orf ON orf.order_id = o.id
  GROUP BY eu.user_id, eu.tenant_id
),
final AS (
  SELECT
    t.tenure_band AS tenure_band,
    m.customer_group AS customer_group,
    COUNT(*) AS customer_count,
    AVG(CAST(co.lifetime_orders AS NUMERIC(18,6))) AS avg_lifetime_orders,
    AVG(co.lifetime_revenue_eur) AS avg_lifetime_revenue_eur,
    {{divide_decimal(SUM(co.lifetime_revenue_eur), NULLIF(SUM(co.non_cancelled_order_count), 0))}} AS avg_order_value_eur,
    {{divide_decimal(100.0 * SUM(co.refunded_order_count), NULLIF(SUM(co.lifetime_orders), 0))}} AS refund_rate_pct
  FROM tenure t
  JOIN membership m ON m.user_id = t.user_id AND m.tenant_id = t.tenant_id
  JOIN customer_orders co ON co.user_id = t.user_id AND co.tenant_id = t.tenant_id
  GROUP BY t.tenure_band, m.customer_group
)
SELECT
  tenure_band,
  customer_group AS "group",
  customer_count,
  avg_lifetime_orders AS avg_lifetime_orders,
  avg_lifetime_revenue_eur AS avg_lifetime_revenue_eur,
  avg_order_value_eur AS avg_order_value_eur,
  refund_rate_pct AS refund_rate_pct
FROM final
ORDER BY
  CASE tenure_band
    WHEN 'under 6 months' THEN 1
    WHEN '6 to 12 months' THEN 2
    WHEN '12 to 24 months' THEN 3
    WHEN 'over 24 months' THEN 4
  END NULLS LAST,
  CASE customer_group
    WHEN 'non-member' THEN 1
    WHEN 'never-redeemed member' THEN 2
    WHEN 'ever-redeemed member' THEN 3
  END NULLS LAST
