WITH loyalty_user_ids AS (
  SELECT DISTINCT user_id FROM loyalty_accounts
),
eligible_orders AS (
  SELECT o.id AS order_id, o.tenant_id AS tenant_id, o.user_id AS user_id, o.placed_at AS placed_at, o.grand_total AS grand_total, o.currency_code AS currency_code, o.status AS status
  FROM orders o
  JOIN loyalty_user_ids lu ON lu.user_id = o.user_id
  WHERE o.placed_at >= DATE '2023-01-01' AND o.placed_at < DATE '2026-01-01'
),
burn_by_user_day AS (
  SELECT user_id, CAST(occurred_at AS DATE) AS burn_date, SUM(ABS(points)) AS day_points
  FROM loyalty_transactions
  WHERE direction = 'burn'
  GROUP BY user_id, CAST(occurred_at AS DATE)
),
classified_orders AS (
  SELECT
    eo.order_id AS order_id,
    eo.user_id AS user_id,
    eo.placed_at AS placed_at,
    eo.grand_total AS grand_total,
    eo.currency_code AS currency_code,
    eo.status AS status,
    bd.day_points AS day_points,
    CASE WHEN bd.user_id IS NOT NULL THEN 'same-day points redemption' ELSE 'no same-day points redemption' END AS order_type
  FROM eligible_orders eo
  LEFT JOIN burn_by_user_day bd
    ON bd.user_id = eo.user_id AND bd.burn_date = CAST(eo.placed_at AS DATE)
),
refund_flags AS (
  SELECT
    co.order_id AS order_id,
    co.order_type AS order_type,
    CASE WHEN EXISTS (SELECT 1 FROM payments p WHERE p.order_id = co.order_id AND p.amount_refunded > 0)
      OR EXISTS (SELECT 1 FROM order_returns r WHERE r.order_id = co.order_id)
    THEN 1 ELSE 0 END AS is_refunded
  FROM classified_orders co
),
order_value_eur AS (
  SELECT
    co.order_id AS order_id,
    co.order_type AS order_type,
    CASE WHEN co.currency_code = 'EUR' THEN co.grand_total
         ELSE CAST({{divide_decimal(co.grand_total, er.rate)}} AS NUMERIC(18,6)) END AS grand_total_eur
  FROM classified_orders co
  LEFT JOIN exchange_rates er
    ON er.base_code = 'EUR' AND er.quote_code = co.currency_code AND er.as_of = CAST(co.placed_at AS DATE)
  WHERE co.status <> 'cancelled'
),
order_counts AS (
  SELECT order_type, COUNT(*) AS order_count, COUNT(DISTINCT user_id) AS distinct_customers, AVG(COALESCE(day_points,0)) AS avg_points_redeemed_that_day
  FROM classified_orders
  GROUP BY order_type
),
refund_rates AS (
  SELECT order_type, AVG(CAST(is_refunded AS NUMERIC(18,6))) * 100 AS refund_rate_pct
  FROM refund_flags
  GROUP BY order_type
),
avg_values AS (
  SELECT order_type, AVG(grand_total_eur) AS avg_order_value_eur
  FROM order_value_eur
  GROUP BY order_type
)
SELECT
  oc.order_type AS order_type,
  oc.order_count AS order_count,
  oc.distinct_customers AS distinct_customers,
  rr.refund_rate_pct AS refund_rate_pct,
  av.avg_order_value_eur AS avg_order_value_eur,
  oc.avg_points_redeemed_that_day AS avg_points_redeemed_that_day
FROM order_counts oc
JOIN refund_rates rr ON rr.order_type = oc.order_type
JOIN avg_values av ON av.order_type = oc.order_type
ORDER BY CASE WHEN oc.order_type = 'same-day points redemption' THEN 0 ELSE 1 END NULLS LAST, oc.order_type NULLS LAST
