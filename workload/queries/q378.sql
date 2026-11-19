WITH population AS (
  SELECT 
    t0.id AS user_id,
    t0.tenant_id AS tenant_id,
    t0.created_at AS user_created_at,
    t1.status AS tenant_status,
    t2.first_redeem_at AS first_redeem_at
  FROM users t0
  JOIN tenants t1 ON t1.id = t0.tenant_id
  JOIN (
    SELECT t3.user_id AS user_id, t3.tenant_id AS tenant_id, MIN(t3.occurred_at) AS first_redeem_at
    FROM loyalty_transactions t3
    WHERE t3.direction = 'burn'
    GROUP BY t3.user_id, t3.tenant_id
  ) t2 ON t2.user_id = t0.id AND t2.tenant_id = t0.tenant_id
  WHERE EXISTS (
    SELECT 1 FROM loyalty_accounts t4
    WHERE t4.user_id = t0.id AND t4.tenant_id = t0.tenant_id
  )
),
base_orders AS (
  SELECT
    t5.id AS order_id,
    t5.tenant_id AS tenant_id,
    t5.user_id AS user_id,
    t5.placed_at AS placed_at,
    t5.status AS status,
    t5.currency_code AS currency_code,
    t5.grand_total AS grand_total,
    CASE WHEN t5.placed_at < t6.first_redeem_at THEN 'before first redemption' ELSE 'after first redemption' END AS period
  FROM orders t5
  JOIN population t6 ON t6.user_id = t5.user_id AND t6.tenant_id = t5.tenant_id
  WHERE t5.placed_at IS NOT NULL
    AND t5.placed_at >= TIMESTAMP '2023-01-01 00:00:00'
    AND t5.placed_at < TIMESTAMP '2026-01-01 00:00:00'
),
periods AS (
  SELECT 'before first redemption' AS period
  UNION ALL
  SELECT 'after first redemption' AS period
),
order_counts AS (
  SELECT
    t7.period AS period,
    COUNT(*) AS total_orders,
    COUNT(DISTINCT t7.user_id) AS distinct_customers
  FROM base_orders t7
  GROUP BY t7.period
),
aov AS (
  SELECT
    t8.period AS period,
    AVG(
      CASE WHEN t8.currency_code = 'EUR' THEN t8.grand_total
           ELSE CAST({{divide_decimal(t8.grand_total, t9.rate)}} AS NUMERIC(18,6))
      END
    ) AS avg_order_value_eur
  FROM base_orders t8
  LEFT JOIN exchange_rates t9
    ON t9.base_code = 'EUR'
   AND t9.quote_code = t8.currency_code
   AND t9.as_of = CAST(t8.placed_at AS DATE)
  WHERE t8.status <> 'cancelled'
  GROUP BY t8.period
),
order_refund_flags AS (
  SELECT
    t10.order_id AS order_id,
    t10.period AS period,
    CASE WHEN COALESCE(t11.has_refund, false) OR COALESCE(t12.has_return, false) THEN 1 ELSE 0 END AS is_refunded
  FROM base_orders t10
  LEFT JOIN (
    SELECT t13.order_id AS order_id, {{bool_or(t13.amount_refunded > 0)}} AS has_refund
    FROM payments t13
    WHERE t13.order_id IS NOT NULL
    GROUP BY t13.order_id
  ) t11 ON t11.order_id = t10.order_id
  LEFT JOIN (
    SELECT DISTINCT t14.order_id AS order_id, true AS has_return
    FROM order_returns t14
  ) t12 ON t12.order_id = t10.order_id
),
refund_rate AS (
  SELECT
    t15.period AS period,
    {{divide_decimal(100.0 * SUM(t15.is_refunded), COUNT(*))}} AS refund_rate_pct
  FROM order_refund_flags t15
  GROUP BY t15.period
),
exposure_before AS (
  SELECT
    'before first redemption' AS period,
    t16.user_id AS user_id,
    GREATEST(
      1,
      FLOOR({{divide_decimal({{seconds_between(COALESCE(t17.first_order_before, t16.user_created_at), t16.first_redeem_at)}}, 86400)}})
    ) AS exposed_days
  FROM population t16
  LEFT JOIN (
    SELECT t18.user_id AS user_id, MIN(t18.placed_at) AS first_order_before
    FROM base_orders t18
    WHERE t18.period = 'before first redemption'
    GROUP BY t18.user_id
  ) t17 ON t17.user_id = t16.user_id
),
exposure_after AS (
  SELECT
    'after first redemption' AS period,
    t19.user_id AS user_id,
    GREATEST(
      1,
      FLOOR(
        {{divide_decimal({{seconds_between(t19.first_redeem_at, COALESCE(
              CASE WHEN t19.tenant_status = 'churned' THEN t20.last_order_after ELSE TIMESTAMP '2025-12-31 00:00:00' END,
              t19.first_redeem_at
            ))}}, 86400)}}
      )
    ) AS exposed_days
  FROM population t19
  LEFT JOIN (
    SELECT t21.user_id AS user_id, MAX(t21.placed_at) AS last_order_after
    FROM base_orders t21
    WHERE t21.period = 'after first redemption'
    GROUP BY t21.user_id
  ) t20 ON t20.user_id = t19.user_id
),
exposure_union AS (
  SELECT * FROM exposure_before
  UNION ALL
  SELECT * FROM exposure_after
),
exposure_years AS (
  SELECT
    t22.period AS period,
    SUM(t22.exposed_days) / 365.0 AS exposed_customer_years
  FROM exposure_union t22
  GROUP BY t22.period
)
SELECT
  t23.period AS period,
  COALESCE(t24.distinct_customers, 0) AS distinct_customers,
  COALESCE(t24.total_orders, 0) AS total_orders,
  COALESCE(t25.avg_order_value_eur, 0) AS avg_order_value_eur,
  COALESCE(t24.total_orders, 0) / NULLIF(t27.exposed_customer_years, 0) AS orders_per_customer_per_year,
  COALESCE(t26.refund_rate_pct, 0) AS refund_rate_pct
FROM periods t23
LEFT JOIN order_counts t24 ON t24.period = t23.period
LEFT JOIN aov t25 ON t25.period = t23.period
LEFT JOIN refund_rate t26 ON t26.period = t23.period
LEFT JOIN exposure_years t27 ON t27.period = t23.period
ORDER BY CASE WHEN t23.period = 'before first redemption' THEN 0 ELSE 1 END NULLS LAST, t23.period NULLS LAST
