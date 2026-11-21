WITH elig_orders AS (
  SELECT o.id AS order_id, o.placed_at AS placed_at
  FROM orders o
  WHERE o.status = 'fulfilled'
    AND o.placed_at >= DATE '2025-01-01'
    AND o.placed_at < DATE '2026-01-01'
),
fulfillment_counts AS (
  SELECT f.order_id AS order_id, COUNT(*) AS n_fulfillments
  FROM fulfillments f
  JOIN elig_orders eo ON eo.order_id = f.order_id
  GROUP BY f.order_id
),
single_fulfillment AS (
  SELECT f.id AS fulfillment_id, f.order_id AS order_id
  FROM fulfillments f
  JOIN fulfillment_counts fc ON fc.order_id = f.order_id AND fc.n_fulfillments = 1
),
shipment_counts AS (
  SELECT s.fulfillment_id AS fulfillment_id, COUNT(*) AS n_shipments
  FROM shipments s
  JOIN single_fulfillment sf ON sf.fulfillment_id = s.fulfillment_id
  GROUP BY s.fulfillment_id
),
single_shipment AS (
  SELECT s.fulfillment_id AS fulfillment_id, s.carrier AS carrier, s.delivered_at AS delivered_at
  FROM shipments s
  JOIN shipment_counts sc ON sc.fulfillment_id = s.fulfillment_id AND sc.n_shipments = 1
),
qualified AS (
  SELECT eo.order_id AS order_id, eo.placed_at AS placed_at, ss.carrier AS carrier, ss.delivered_at AS delivered_at
  FROM elig_orders eo
  JOIN single_fulfillment sf ON sf.order_id = eo.order_id
  JOIN single_shipment ss ON ss.fulfillment_id = sf.fulfillment_id
  WHERE ss.delivered_at IS NOT NULL
),
labeled AS (
  SELECT
    order_id,
    CASE WHEN placed_at < DATE '2025-11-01' THEN 'baseline' ELSE 'collapse' END AS period,
    CASE WHEN carrier = 'Albion Parcel' THEN 'Albion Parcel' ELSE 'All other carriers' END AS carrier_group,
    {{divide_decimal({{seconds_between(placed_at, delivered_at)}}, 86400.0)}} AS delivery_days
  FROM qualified
),
agg AS (
  SELECT
    period,
    carrier_group,
    COUNT(*) AS orders_fully_delivered,
    AVG(delivery_days) AS avg_delivery_days,
    {{divide_decimal(100.0 * SUM(CASE WHEN delivery_days <= 5 THEN 1 ELSE 0 END), COUNT(*))}} AS pct_within_5_days
  FROM labeled
  GROUP BY period, carrier_group
)
SELECT
  carrier_group,
  period,
  orders_fully_delivered,
  avg_delivery_days AS avg_delivery_days,
  pct_within_5_days AS pct_within_5_days,
  {{divide_decimal(100.0 * orders_fully_delivered, SUM(orders_fully_delivered) OVER (PARTITION BY period))}} AS share_of_period_orders_pct
FROM agg
ORDER BY period ASC NULLS LAST, carrier_group ASC NULLS LAST
