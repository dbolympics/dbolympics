WITH redemptions AS (
  SELECT cr.id AS redemption_id, cr.order_id AS order_id, cr.discount_amount AS discount_amount, cr.currency_code AS currency_code, cr.redeemed_at AS redeemed_at, c.code AS code
  FROM coupon_redemptions cr
  JOIN coupons c ON c.id = cr.coupon_id
  WHERE cr.redeemed_at >= DATE '2025-01-01' AND cr.redeemed_at < DATE '2026-01-01'
),
discount_eur AS (
  SELECT r.code AS code, r.order_id AS order_id, CAST({{divide_decimal(r.discount_amount, er.rate)}} AS NUMERIC(18,6)) AS discount_amount_eur
  FROM redemptions r
  JOIN exchange_rates er
    ON er.base_code = 'EUR' AND er.quote_code = r.currency_code AND er.as_of = CAST(r.redeemed_at AS date)
),
code_orders AS (
  SELECT DISTINCT code, order_id FROM redemptions
),
orders_eur AS (
  SELECT co.code AS code, co.order_id AS order_id, CAST({{divide_decimal(o.grand_total, er.rate)}} AS NUMERIC(18,6)) AS grand_total_eur
  FROM code_orders co
  JOIN orders o ON o.id = co.order_id
  JOIN exchange_rates er
    ON er.base_code = 'EUR' AND er.quote_code = o.currency_code AND er.as_of = CAST(o.placed_at AS date)
),
returns_eur AS (
  SELECT co.code AS code, co.order_id AS order_id, SUM(CAST({{divide_decimal(orr.refund_total, er.rate)}} AS NUMERIC(18,6))) AS order_refund_eur
  FROM code_orders co
  JOIN order_returns orr ON orr.order_id = co.order_id
  JOIN exchange_rates er
    ON er.base_code = 'EUR' AND er.quote_code = orr.currency_code AND er.as_of = CAST(orr.refunded_at AS date)
  GROUP BY co.code, co.order_id
),
discount_agg AS (
  SELECT code, COUNT(*) AS times_redeemed, COUNT(DISTINCT order_id) AS orders_count, SUM(discount_amount_eur) AS discount_given_eur
  FROM discount_eur
  GROUP BY code
),
refund_agg AS (
  SELECT code, SUM(order_refund_eur) AS refund_amount_eur, COUNT(*) AS orders_with_return
  FROM returns_eur
  GROUP BY code
),
order_value_agg AS (
  SELECT code, AVG(grand_total_eur) AS avg_order_value_eur
  FROM orders_eur
  GROUP BY code
)
SELECT
  d.code AS code,
  d.times_redeemed AS times_redeemed,
  d.orders_count AS orders_count,
  d.discount_given_eur AS discount_given_eur,
  COALESCE(r.refund_amount_eur, 0) AS refund_amount_eur,
  d.discount_given_eur + COALESCE(r.refund_amount_eur, 0) AS net_cost_eur,
  {{divide_decimal(100.0 * COALESCE(r.orders_with_return, 0), NULLIF(d.orders_count, 0))}} AS refund_rate_pct,
  ov.avg_order_value_eur AS avg_order_value_eur
FROM discount_agg d
LEFT JOIN refund_agg r ON r.code = d.code
LEFT JOIN order_value_agg ov ON ov.code = d.code
ORDER BY net_cost_eur DESC NULLS FIRST, d.code ASC NULLS LAST
{{fetch_first(20)}}
