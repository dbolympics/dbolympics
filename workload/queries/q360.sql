WITH months AS (
  SELECT DISTINCT month_label, month_start
  FROM calendar_days
  WHERE calendar_date BETWEEN DATE '2023-01-01' AND DATE '2025-12-31'
),
latest_sub AS (
  SELECT tenant_id, user_id, status,
         ROW_NUMBER() OVER (PARTITION BY tenant_id, user_id ORDER BY started_at DESC NULLS FIRST, id DESC NULLS FIRST) AS rn
  FROM subscriptions
),
confirmed_canceled_users AS (
  SELECT tenant_id, user_id
  FROM latest_sub
  WHERE rn = 1 AND status = 'canceled'
),
orphan_orders AS (
  SELECT
    o.tenant_id AS tenant_id,
    o.user_id AS user_id,
    o.id AS order_id,
    cd.month_label AS month_label,
    CAST({{divide_decimal(od.amount, er.rate)}} AS NUMERIC(18,6)) AS discount_amount_eur
  FROM order_discounts od
  JOIN discounts d ON d.id = od.discount_id AND d.tenant_id = od.tenant_id
  JOIN orders o ON o.id = od.order_id AND o.tenant_id = od.tenant_id
  JOIN calendar_days cd ON cd.calendar_date = CAST(o.placed_at AS DATE)
  JOIN exchange_rates er ON er.base_code = 'EUR' AND er.quote_code = od.currency_code AND er.as_of = CAST(o.placed_at AS DATE)
  JOIN confirmed_canceled_users ccu ON ccu.tenant_id = o.tenant_id AND ccu.user_id = o.user_id
  WHERE d.name = 'Subscription delivery (prepaid)'
    AND o.status != 'cancelled'
    AND o.placed_at >= TIMESTAMP '2023-01-01'
    AND o.placed_at < TIMESTAMP '2026-01-01'
    AND NOT EXISTS (
      SELECT 1 FROM subscriptions s
      WHERE s.tenant_id = o.tenant_id
        AND s.user_id = o.user_id
        AND s.status IN ('trialing','active','past_due')
        AND s.started_at <= o.placed_at
        AND (s.ended_at IS NULL OR s.ended_at >= o.placed_at)
    )
),
monthly AS (
  SELECT m.month_label AS month_label, m.month_start AS month_start,
         COUNT(oo.order_id) AS orphan_order_count,
         COUNT(DISTINCT oo.user_id) AS distinct_customers,
         COALESCE(SUM(oo.discount_amount_eur),0) AS total_discount_eur
  FROM months m
  LEFT JOIN orphan_orders oo ON oo.month_label = m.month_label
  GROUP BY m.month_label, m.month_start
)
SELECT
  month_label AS month,
  orphan_order_count AS orphan_orders,
  distinct_customers,
  total_discount_eur AS total_discount_eur,
  SUM(total_discount_eur) OVER (ORDER BY month_start NULLS LAST, month_label NULLS LAST ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW) AS cumulative_discount_eur
FROM monthly
ORDER BY month_start NULLS LAST, month_label NULLS LAST
