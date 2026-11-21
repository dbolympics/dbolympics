WITH t0 AS (
  SELECT
    o.id AS order_id,
    o.placed_at AS placed_at,
    o.shipping_address_id AS shipping_address_id,
    s.carrier AS carrier,
    s.delivered_at AS delivered_at,
    ({{divide_decimal({{seconds_between(o.placed_at, s.delivered_at)}}, 86400.0)}}) AS delivery_days
  FROM orders o
  JOIN fulfillments f ON f.order_id = o.id
  JOIN shipments s ON s.fulfillment_id = f.id
  WHERE o.placed_at >= DATE '2025-01-01'
    AND o.placed_at < DATE '2026-01-01'
    AND o.status = 'fulfilled'
    AND s.delivered_at IS NOT NULL
    AND (SELECT COUNT(*) FROM fulfillments f2 WHERE f2.order_id = o.id) = 1
    AND (SELECT COUNT(*) FROM shipments s2 WHERE s2.fulfillment_id = f.id) = 1
),
t1 AS (
  SELECT
    t0.order_id AS order_id,
    t0.delivery_days AS delivery_days,
    CASE
      WHEN t0.carrier = 'Lowlands Express' AND c.name IN ('Netherlands', 'Belgium', 'France') THEN 'Lowlands core (NL/BE/FR)'
      WHEN t0.carrier = 'Lowlands Express' THEN 'Lowlands non-core (other countries)'
      ELSE 'All other carriers'
    END AS lane_group
  FROM t0
  LEFT JOIN addresses a ON a.id = t0.shipping_address_id
  LEFT JOIN countries c ON c.id = a.country_id
),
t2 AS (
  SELECT
    t1.lane_group AS lane_group,
    COUNT(*) AS orders_fully_delivered,
    AVG(t1.delivery_days) AS avg_delivery_days,
    {{divide_decimal(100.0 * SUM(CASE WHEN t1.delivery_days <= 5 THEN 1 ELSE 0 END), COUNT(*))}} AS pct_within_5_days
  FROM t1
  GROUP BY t1.lane_group
),
t3 AS (
  SELECT COUNT(*) AS total_orders FROM t1
)
SELECT
  t2.lane_group AS lane_group,
  t2.orders_fully_delivered AS orders_fully_delivered,
  t2.avg_delivery_days AS avg_delivery_days,
  t2.pct_within_5_days AS pct_within_5_days,
  {{divide_decimal(100.0 * t2.orders_fully_delivered, t3.total_orders)}} AS share_of_orders_pct
FROM t2
CROSS JOIN t3
ORDER BY
  CASE t2.lane_group
    WHEN 'Lowlands core (NL/BE/FR)' THEN 1
    WHEN 'Lowlands non-core (other countries)' THEN 2
    ELSE 3
  END NULLS LAST,
  t2.lane_group NULLS LAST
