WITH apparel_tenants AS (
  SELECT id AS tenant_id
  FROM tenants
  WHERE industry = 'Apparel & Footwear'
),
eligible_users AS (
  SELECT DISTINCT u.id AS user_id, u.tenant_id AS tenant_id, u.created_at AS created_at
  FROM users u
  JOIN apparel_tenants t ON t.tenant_id = u.tenant_id
  WHERE u.is_staff = false
    AND EXISTS (
      SELECT 1 FROM orders o
      WHERE o.user_id = u.id
        AND o.tenant_id = u.tenant_id
        AND o.placed_at >= TIMESTAMP '2023-01-01'
        AND o.placed_at < TIMESTAMP '2026-01-01'
    )
),
loyalty_group AS (
  SELECT
    eu.user_id AS user_id,
    CASE
      WHEN la.user_id IS NULL THEN 'non-member'
      WHEN lb.user_id IS NOT NULL THEN 'ever-redeemed member'
      ELSE 'never-redeemed member'
    END AS customer_group
  FROM eligible_users eu
  LEFT JOIN (SELECT DISTINCT user_id FROM loyalty_accounts) la
    ON la.user_id = eu.user_id
  LEFT JOIN (SELECT DISTINCT user_id FROM loyalty_transactions WHERE direction = 'burn') lb
    ON lb.user_id = eu.user_id
),
tenure AS (
  SELECT
    eu.user_id AS user_id,
    CASE
      WHEN (DATE '2025-12-31' - CAST(eu.created_at AS date)) < 182 THEN 'under 6 months'
      WHEN (DATE '2025-12-31' - CAST(eu.created_at AS date)) < 365 THEN '6 to 12 months'
      WHEN (DATE '2025-12-31' - CAST(eu.created_at AS date)) < 730 THEN '12 to 24 months'
      ELSE 'over 24 months'
    END AS tenure_band
  FROM eligible_users eu
),
orders_scoped AS (
  SELECT
    o.id AS order_id,
    o.user_id AS user_id,
    o.status AS status,
    CASE WHEN o.status <> 'cancelled' THEN
      CASE WHEN o.currency_code = 'EUR' THEN CAST(o.grand_total AS NUMERIC(18,6))
           ELSE CAST({{divide_decimal(o.grand_total, er.rate)}} AS NUMERIC(18,6)) END
    ELSE NULL END AS revenue_eur,
    CASE WHEN o.status <> 'cancelled' THEN 1 ELSE 0 END AS is_noncancelled,
    CASE WHEN EXISTS (SELECT 1 FROM payments p WHERE p.order_id = o.id AND p.amount_refunded > 0)
         OR EXISTS (SELECT 1 FROM order_returns r WHERE r.order_id = o.id)
    THEN 1 ELSE 0 END AS is_refunded
  FROM orders o
  JOIN eligible_users eu ON eu.user_id = o.user_id AND eu.tenant_id = o.tenant_id
  LEFT JOIN exchange_rates er
    ON er.base_code = 'EUR'
    AND er.quote_code = o.currency_code
    AND er.as_of = CAST(o.placed_at AS date)
),
user_agg AS (
  SELECT
    user_id,
    COUNT(*) AS lifetime_orders,
    SUM(is_noncancelled) AS noncancelled_orders,
    SUM(COALESCE(revenue_eur, 0)) AS lifetime_revenue_eur,
    SUM(is_refunded) AS refunded_orders
  FROM orders_scoped
  GROUP BY user_id
),
user_level AS (
  SELECT
    t.tenure_band AS tenure_band,
    lg.customer_group AS customer_group,
    ua.lifetime_orders AS lifetime_orders,
    ua.noncancelled_orders AS noncancelled_orders,
    ua.lifetime_revenue_eur AS lifetime_revenue_eur,
    ua.refunded_orders AS refunded_orders
  FROM eligible_users eu
  JOIN tenure t ON t.user_id = eu.user_id
  JOIN loyalty_group lg ON lg.user_id = eu.user_id
  JOIN user_agg ua ON ua.user_id = eu.user_id
)
SELECT
  tenure_band,
  customer_group AS "group",
  COUNT(*) AS customer_count,
  AVG(CAST(lifetime_orders AS NUMERIC(18,6))) AS avg_lifetime_orders,
  AVG(lifetime_revenue_eur) AS avg_lifetime_revenue_eur,
  ({{divide_decimal(SUM(lifetime_revenue_eur), NULLIF(SUM(noncancelled_orders), 0))}}) AS avg_order_value_eur,
  ({{divide_decimal(100.0 * SUM(refunded_orders), NULLIF(SUM(lifetime_orders), 0))}}) AS refund_rate_pct
FROM user_level
GROUP BY tenure_band, customer_group
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
