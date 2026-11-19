WITH lu AS (
  SELECT la.tenant_id AS tenant_id, la.user_id AS user_id, MIN(la.enrolled_at) AS enrolled_at
  FROM loyalty_accounts la
  GROUP BY la.tenant_id, la.user_id
),
lu2 AS (
  SELECT t0.tenant_id AS tenant_id, t0.user_id AS user_id, t0.enrolled_at AS enrolled_at, u0.created_at AS user_created_at
  FROM lu t0
  JOIN users u0 ON u0.tenant_id = t0.tenant_id AND u0.id = t0.user_id
),
ord AS (
  SELECT
    o0.tenant_id AS tenant_id,
    o0.user_id AS user_id,
    o0.id AS order_id,
    o0.placed_at AS placed_at,
    o0.status AS status,
    o0.currency_code AS currency_code,
    o0.grand_total AS grand_total,
    CASE WHEN o0.placed_at < lu2.enrolled_at THEN 'pre-enrollment' ELSE 'post-enrollment' END AS period
  FROM orders o0
  JOIN lu2 ON lu2.tenant_id = o0.tenant_id AND lu2.user_id = o0.user_id
  WHERE o0.placed_at IS NOT NULL
),
ord_refund AS (
  SELECT
    ord.tenant_id AS tenant_id,
    ord.order_id AS order_id,
    ord.period AS period,
    CASE WHEN EXISTS (
            SELECT 1 FROM payments p0
            WHERE p0.tenant_id = ord.tenant_id AND p0.order_id = ord.order_id AND p0.amount_refunded > 0
          )
          OR EXISTS (
            SELECT 1 FROM order_returns r0
            WHERE r0.tenant_id = ord.tenant_id AND r0.order_id = ord.order_id
          )
     THEN 1 ELSE 0 END AS is_refunded
  FROM ord
),
ord_eur AS (
  SELECT
    ord.tenant_id AS tenant_id,
    ord.order_id AS order_id,
    ord.period AS period,
    CASE WHEN ord.currency_code = 'EUR' THEN ord.grand_total
         ELSE CAST({{divide_decimal(ord.grand_total, NULLIF(er0.rate, 0))}} AS NUMERIC(18,6))
    END AS eur_amount
  FROM ord
  LEFT JOIN exchange_rates er0
    ON er0.base_code = 'EUR'
   AND er0.quote_code = ord.currency_code
   AND er0.as_of = CAST(ord.placed_at AS DATE)
  WHERE ord.status <> 'cancelled'
),
m_orders AS (
  SELECT ord.period AS period, COUNT(*) AS total_orders, COUNT(DISTINCT ord.user_id) AS distinct_customers
  FROM ord
  GROUP BY ord.period
),
m_aov AS (
  SELECT ord_eur.period AS period, AVG(ord_eur.eur_amount) AS avg_order_value_eur
  FROM ord_eur
  GROUP BY ord_eur.period
),
m_refund AS (
  SELECT ord_refund.period AS period, {{divide_decimal(100.0 * SUM(ord_refund.is_refunded), COUNT(*))}} AS refund_rate_pct
  FROM ord_refund
  GROUP BY ord_refund.period
),
cust_pre AS (
  SELECT ord.tenant_id AS tenant_id, ord.user_id AS user_id, MIN(ord.placed_at) AS first_pre_order_at
  FROM ord
  WHERE ord.period = 'pre-enrollment'
  GROUP BY ord.tenant_id, ord.user_id
),
cust_post AS (
  SELECT ord.tenant_id AS tenant_id, ord.user_id AS user_id, MAX(ord.placed_at) AS last_post_order_at
  FROM ord
  WHERE ord.period = 'post-enrollment'
  GROUP BY ord.tenant_id, ord.user_id
),
cust_exposure AS (
  SELECT
    lu2.tenant_id AS tenant_id,
    lu2.user_id AS user_id,
    GREATEST(1, {{date_diff_days(COALESCE(cp0.first_pre_order_at, lu2.user_created_at), lu2.enrolled_at)}}) AS pre_exposed_days,
    GREATEST(1, {{date_diff_days(lu2.enrolled_at, COALESCE(cpo0.last_post_order_at, DATE '2025-12-31'))}}) AS post_exposed_days
  FROM lu2
  LEFT JOIN cust_pre cp0 ON cp0.tenant_id = lu2.tenant_id AND cp0.user_id = lu2.user_id
  LEFT JOIN cust_post cpo0 ON cpo0.tenant_id = lu2.tenant_id AND cpo0.user_id = lu2.user_id
),
exposure_by_period AS (
  SELECT 'pre-enrollment' AS period, SUM(ce.pre_exposed_days) AS total_exposed_days FROM cust_exposure ce
  UNION ALL
  SELECT 'post-enrollment' AS period, SUM(ce.post_exposed_days) AS total_exposed_days FROM cust_exposure ce
),
periods AS (
  SELECT 'pre-enrollment' AS period
  UNION ALL
  SELECT 'post-enrollment' AS period
)
SELECT
  p0.period AS period,
  COALESCE(mo0.distinct_customers, 0) AS distinct_customers,
  COALESCE(mo0.total_orders, 0) AS total_orders,
  COALESCE(ma0.avg_order_value_eur, 0) AS avg_order_value_eur,
  COALESCE(mo0.total_orders, 0) / NULLIF({{divide_decimal(COALESCE(ep0.total_exposed_days, 0), 365.0)}}, 0) AS orders_per_customer_per_year,
  COALESCE(mr0.refund_rate_pct, 0) AS refund_rate_pct
FROM periods p0
LEFT JOIN m_orders mo0 ON mo0.period = p0.period
LEFT JOIN m_aov ma0 ON ma0.period = p0.period
LEFT JOIN m_refund mr0 ON mr0.period = p0.period
LEFT JOIN exposure_by_period ep0 ON ep0.period = p0.period
ORDER BY CASE WHEN p0.period = 'pre-enrollment' THEN 0 ELSE 1 END NULLS LAST, p0.period NULLS LAST
