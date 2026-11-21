WITH loyalty_members AS (
  SELECT DISTINCT tenant_id, user_id FROM loyalty_accounts
),
population AS (
  SELECT DISTINCT o.tenant_id AS tenant_id, o.user_id AS user_id
  FROM orders o
  JOIN loyalty_members lm ON lm.tenant_id = o.tenant_id AND lm.user_id = o.user_id
  WHERE o.placed_at >= DATE '2023-01-01' AND o.placed_at < DATE '2026-01-01'
),
orders_base AS (
  SELECT o.tenant_id AS tenant_id, o.user_id AS user_id, o.id AS order_id, o.status AS status, o.placed_at AS placed_at, o.grand_total AS grand_total, o.currency_code AS currency_code
  FROM orders o
  JOIN population p ON p.tenant_id = o.tenant_id AND p.user_id = o.user_id
),
payment_refund AS (
  SELECT tenant_id, order_id, MAX(CASE WHEN amount_refunded > 0 THEN 1 ELSE 0 END) AS has_refund
  FROM payments
  WHERE order_id IS NOT NULL
  GROUP BY tenant_id, order_id
),
return_flag AS (
  SELECT DISTINCT tenant_id, order_id
  FROM order_returns
),
orders_enriched AS (
  SELECT
    ob.tenant_id AS tenant_id, ob.user_id AS user_id, ob.order_id AS order_id, ob.status AS status, ob.placed_at AS placed_at,
    CASE WHEN ob.currency_code = 'EUR' THEN CAST(ob.grand_total AS NUMERIC(18,6))
         ELSE CAST({{divide_decimal(ob.grand_total, er.rate)}} AS NUMERIC(18,6)) END AS grand_total_eur,
    CASE WHEN COALESCE(pr.has_refund,0) = 1 OR rf.order_id IS NOT NULL THEN 1 ELSE 0 END AS is_refunded
  FROM orders_base ob
  LEFT JOIN exchange_rates er
    ON er.base_code = 'EUR' AND er.quote_code = ob.currency_code AND er.as_of = CAST(ob.placed_at AS DATE)
  LEFT JOIN payment_refund pr ON pr.tenant_id = ob.tenant_id AND pr.order_id = ob.order_id
  LEFT JOIN return_flag rf ON rf.tenant_id = ob.tenant_id AND rf.order_id = ob.order_id
),
member_orders AS (
  SELECT
    tenant_id, user_id,
    SUM(CASE WHEN status <> 'cancelled' THEN COALESCE(grand_total_eur,0) ELSE 0 END) AS lifetime_revenue_eur,
    COUNT(*) AS lifetime_orders,
    MAX(placed_at) AS last_order_at,
    SUM(is_refunded) AS refunded_orders
  FROM orders_enriched
  GROUP BY tenant_id, user_id
),
tx_value AS (
  SELECT lt.tenant_id AS tenant_id, lt.user_id AS user_id, lt.direction AS direction, lt.occurred_at AS occurred_at,
    {{divide_decimal(lt.points, lp.points_per_currency)}} AS points_currency_amount,
    lp.currency_code AS currency_code
  FROM loyalty_transactions lt
  JOIN loyalty_accounts la ON la.id = lt.loyalty_account_id
  JOIN loyalty_programs lp ON lp.id = la.loyalty_program_id
  JOIN population p ON p.tenant_id = lt.tenant_id AND p.user_id = lt.user_id
),
tx_value_eur AS (
  SELECT tenant_id, user_id, direction,
    CASE WHEN currency_code = 'EUR' THEN points_currency_amount
         ELSE CAST(points_currency_amount / er.rate AS NUMERIC(18,6)) END AS value_eur
  FROM tx_value tv
  LEFT JOIN exchange_rates er
    ON er.base_code = 'EUR' AND er.quote_code = tv.currency_code AND er.as_of = CAST(tv.occurred_at AS DATE)
),
member_loyalty AS (
  SELECT tenant_id, user_id,
    MAX(CASE WHEN direction = 'burn' THEN 1 ELSE 0 END) AS ever_redeemed,
    SUM(CASE WHEN direction = 'earn' THEN value_eur ELSE 0 END) AS earned_eur,
    SUM(CASE WHEN direction = 'burn' THEN value_eur ELSE 0 END) AS redeemed_eur
  FROM tx_value_eur
  GROUP BY tenant_id, user_id
),
member_full AS (
  SELECT
    mo.tenant_id AS tenant_id, mo.user_id AS user_id,
    mo.lifetime_revenue_eur AS lifetime_revenue_eur, mo.lifetime_orders AS lifetime_orders, mo.refunded_orders AS refunded_orders,
    {{divide_decimal({{seconds_between(u.created_at, mo.last_order_at)}}, 86400.0)}} AS tenure_days,
    COALESCE(ml.ever_redeemed,0) AS ever_redeemed,
    COALESCE(ml.earned_eur,0) AS earned_eur,
    COALESCE(ml.redeemed_eur,0) AS redeemed_eur
  FROM member_orders mo
  JOIN users u ON u.tenant_id = mo.tenant_id AND u.id = mo.user_id
  LEFT JOIN member_loyalty ml ON ml.tenant_id = mo.tenant_id AND ml.user_id = mo.user_id
),
ranked AS (
  SELECT
    mf.*,
    NTILE(4) OVER (ORDER BY lifetime_revenue_eur DESC NULLS FIRST, tenant_id NULLS LAST, user_id NULLS LAST) AS quartile
  FROM member_full mf
)
SELECT
  CASE WHEN quartile = 1 THEN 'Top 25% by lifetime revenue' ELSE 'Remaining 75%' END AS performance_group,
  COUNT(*) AS member_count,
  AVG(lifetime_revenue_eur) AS avg_lifetime_revenue_eur,
  AVG(CAST(lifetime_orders AS NUMERIC(18,6))) AS avg_lifetime_orders,
  AVG(tenure_days) AS avg_tenure_days,
  100.0 * AVG(CAST(ever_redeemed AS NUMERIC(18,6))) AS pct_who_ever_redeemed_points,
  100.0 * SUM(redeemed_eur) / NULLIF(SUM(earned_eur), 0) AS own_redemption_rate_pct,
  {{divide_decimal(100.0 * SUM(refunded_orders), NULLIF(SUM(lifetime_orders), 0))}} AS refund_rate_pct
FROM ranked
GROUP BY CASE WHEN quartile = 1 THEN 'Top 25% by lifetime revenue' ELSE 'Remaining 75%' END
ORDER BY MIN(quartile) NULLS LAST
