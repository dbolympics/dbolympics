WITH population AS (
  SELECT u.id AS user_id,
         CASE
           WHEN (DATE '2025-12-31' - CAST(u.created_at AS DATE)) < 182 THEN 'under 6 months'
           WHEN (DATE '2025-12-31' - CAST(u.created_at AS DATE)) < 365 THEN '6 to 12 months'
           WHEN (DATE '2025-12-31' - CAST(u.created_at AS DATE)) < 730 THEN '12 to 24 months'
           ELSE 'over 24 months'
         END AS tenure_band,
         CASE WHEN EXISTS (
                SELECT 1 FROM loyalty_accounts la WHERE la.user_id = u.id
              ) THEN 'loyalty member' ELSE 'non-member' END AS segment
  FROM users u
  WHERE u.is_staff = false
    AND EXISTS (
      SELECT 1 FROM orders o
      WHERE o.user_id = u.id
        AND COALESCE(o.placed_at, o.created_at) >= TIMESTAMP '2023-01-01'
        AND COALESCE(o.placed_at, o.created_at) < TIMESTAMP '2026-01-01'
    )
),
grain_keys AS (
  SELECT DISTINCT tenure_band, segment FROM population
),
t_customer_count AS (
  SELECT tenure_band, segment, COUNT(*) AS customer_count
  FROM population
  GROUP BY tenure_band, segment
),
t_lifetime_orders AS (
  SELECT p.tenure_band AS tenure_band, p.segment AS segment, COUNT(o.id) AS total_orders
  FROM population p
  JOIN orders o ON o.user_id = p.user_id
  GROUP BY p.tenure_band, p.segment
),
t_refunded_orders AS (
  SELECT p.tenure_band AS tenure_band, p.segment AS segment, COUNT(o.id) AS refunded_orders
  FROM population p
  JOIN orders o ON o.user_id = p.user_id
  WHERE EXISTS (SELECT 1 FROM payments pay WHERE pay.order_id = o.id AND pay.amount_refunded > 0)
     OR EXISTS (SELECT 1 FROM order_returns r WHERE r.order_id = o.id)
  GROUP BY p.tenure_band, p.segment
),
t_revenue AS (
  SELECT p.tenure_band AS tenure_band, p.segment AS segment,
         SUM(CASE WHEN o.currency_code = 'EUR' THEN o.grand_total
                  ELSE CAST({{divide_decimal(o.grand_total, NULLIF(er.rate, 0))}} AS NUMERIC(18,6)) END) AS total_revenue_eur,
         COUNT(o.id) AS non_cancelled_orders
  FROM population p
  JOIN orders o ON o.user_id = p.user_id
  LEFT JOIN exchange_rates er
    ON er.base_code = 'EUR'
   AND er.quote_code = o.currency_code
   AND er.as_of = CAST(COALESCE(o.placed_at, o.created_at) AS DATE)
  WHERE o.status <> 'cancelled'
  GROUP BY p.tenure_band, p.segment
)
SELECT
  gk.tenure_band AS tenure_band,
  gk.segment AS segment,
  COALESCE(cc.customer_count, 0) AS customer_count,
  {{divide_decimal(CAST(COALESCE(lo.total_orders, 0) AS numeric(18,6)), NULLIF(cc.customer_count, 0))}} AS avg_lifetime_orders,
  {{divide_decimal(COALESCE(rev.total_revenue_eur, 0), NULLIF(cc.customer_count, 0))}} AS avg_lifetime_revenue_eur,
  {{divide_decimal(COALESCE(rev.total_revenue_eur, 0), NULLIF(rev.non_cancelled_orders, 0))}} AS avg_order_value_eur,
  {{divide_decimal(100.0 * COALESCE(ro.refunded_orders, 0), NULLIF(lo.total_orders, 0))}} AS refund_rate_pct
FROM grain_keys gk
LEFT JOIN t_customer_count cc ON cc.tenure_band = gk.tenure_band AND cc.segment = gk.segment
LEFT JOIN t_lifetime_orders lo ON lo.tenure_band = gk.tenure_band AND lo.segment = gk.segment
LEFT JOIN t_refunded_orders ro ON ro.tenure_band = gk.tenure_band AND ro.segment = gk.segment
LEFT JOIN t_revenue rev ON rev.tenure_band = gk.tenure_band AND rev.segment = gk.segment
ORDER BY
  CASE gk.tenure_band
    WHEN 'under 6 months' THEN 1
    WHEN '6 to 12 months' THEN 2
    WHEN '12 to 24 months' THEN 3
    WHEN 'over 24 months' THEN 4
  END NULLS LAST,
  CASE gk.segment WHEN 'loyalty member' THEN 1 ELSE 2 END NULLS LAST
