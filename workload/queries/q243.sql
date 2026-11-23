WITH order_fulfillment_counts AS (
  SELECT order_id, COUNT(*) AS fulfillment_count
  FROM fulfillments
  GROUP BY order_id
),
fulfillment_shipment_counts AS (
  SELECT fulfillment_id, COUNT(*) AS shipment_count
  FROM shipments
  GROUP BY fulfillment_id
),
eligible_orders AS (
  SELECT
    o.id AS order_id,
    o.placed_at AS placed_at,
    o.shipping_address_id AS shipping_address_id,
    f.id AS fulfillment_id
  FROM orders o
  JOIN order_fulfillment_counts ofc
    ON ofc.order_id = o.id AND ofc.fulfillment_count = 1
  JOIN fulfillments f
    ON f.order_id = o.id
  WHERE o.status = 'fulfilled'
    AND o.placed_at >= DATE '2025-01-01'
    AND o.placed_at < DATE '2026-01-01'
),
eligible_with_shipment AS (
  SELECT
    eo.order_id AS order_id,
    eo.placed_at AS placed_at,
    eo.shipping_address_id AS shipping_address_id,
    s.carrier AS carrier,
    s.delivered_at AS delivered_at
  FROM eligible_orders eo
  JOIN fulfillment_shipment_counts fsc
    ON fsc.fulfillment_id = eo.fulfillment_id AND fsc.shipment_count = 1
  JOIN shipments s
    ON s.fulfillment_id = eo.fulfillment_id
  WHERE s.delivered_at IS NOT NULL
),
order_lane AS (
  SELECT
    ews.order_id AS order_id,
    {{divide_decimal({{seconds_between(ews.placed_at, ews.delivered_at)}}, 86400.0)}} AS delivery_days,
    CASE
      WHEN ews.carrier = 'Lowlands Express' AND c.name IN ('Netherlands', 'Belgium', 'France')
        THEN 'Lowlands core (NL/BE/FR)'
      WHEN ews.carrier = 'Lowlands Express'
        THEN 'Lowlands non-core (other countries)'
      ELSE 'All other carriers combined'
    END AS lane_group
  FROM eligible_with_shipment ews
  LEFT JOIN addresses a ON a.id = ews.shipping_address_id
  LEFT JOIN countries c ON c.id = a.country_id
),
lane_groups AS (
  SELECT 'Lowlands core (NL/BE/FR)' AS lane_group, 1 AS sort_order
  UNION ALL
  SELECT 'Lowlands non-core (other countries)', 2
  UNION ALL
  SELECT 'All other carriers combined', 3
),
lane_stats AS (
  SELECT
    lane_group,
    COUNT(*) AS orders_fully_delivered,
    AVG(delivery_days) AS avg_delivery_days,
    AVG(CASE WHEN delivery_days <= 5 THEN 1.0 ELSE 0.0 END) * 100 AS pct_within_5_days
  FROM order_lane
  GROUP BY lane_group
),
totals AS (
  SELECT SUM(orders_fully_delivered) AS total_orders FROM lane_stats
)
SELECT
  lg.lane_group AS lane_group,
  COALESCE(ls.orders_fully_delivered, 0) AS orders_fully_delivered,
  ls.avg_delivery_days AS avg_delivery_days,
  ls.pct_within_5_days AS pct_within_5_days,
  {{divide_decimal(CAST(COALESCE(ls.orders_fully_delivered, 0) AS numeric(18,6)), NULLIF(t.total_orders, 0))}} * 100 AS share_of_orders_pct
FROM lane_groups lg
LEFT JOIN lane_stats ls ON ls.lane_group = lg.lane_group
CROSS JOIN totals t
ORDER BY lg.sort_order NULLS LAST
