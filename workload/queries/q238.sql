WITH order_fulfillment_counts AS (
  SELECT order_id, COUNT(*) AS cnt
  FROM fulfillments
  GROUP BY order_id
),
fulfillment_shipment_counts AS (
  SELECT fulfillment_id, COUNT(*) AS cnt
  FROM shipments
  GROUP BY fulfillment_id
),
base AS (
  SELECT
    o.id AS order_id,
    o.placed_at AS placed_at,
    s.carrier AS carrier,
    s.delivered_at AS delivered_at
  FROM orders o
  JOIN fulfillments f ON f.order_id = o.id
  JOIN shipments s ON s.fulfillment_id = f.id
  JOIN order_fulfillment_counts ofc ON ofc.order_id = o.id
  JOIN fulfillment_shipment_counts fsc ON fsc.fulfillment_id = f.id
  WHERE o.status = 'fulfilled'
    AND o.placed_at >= DATE '2025-01-01'
    AND o.placed_at < DATE '2026-01-01'
    AND ofc.cnt = 1
    AND fsc.cnt = 1
    AND s.delivered_at IS NOT NULL
),
scored AS (
  SELECT
    order_id,
    CASE WHEN carrier IN ('Albion Parcel','Landfall Freight','Lowlands Express') THEN 'Weak three' ELSE 'All other carriers' END AS carrier_group,
    {{date_diff_days(placed_at, delivered_at)}} AS delivery_days
  FROM base
)
SELECT
  carrier_group,
  COUNT(*) AS orders_fully_delivered,
  AVG(CAST(delivery_days AS NUMERIC(18,6))) AS avg_delivery_days,
  {{divide_decimal(100.0 * SUM(CASE WHEN delivery_days <= 5 THEN 1 ELSE 0 END), COUNT(*))}} AS pct_within_5_days,
  {{divide_decimal(100.0 * COUNT(*), SUM(COUNT(*)) OVER ())}} AS share_of_orders_pct
FROM scored
GROUP BY carrier_group
ORDER BY carrier_group ASC NULLS LAST
