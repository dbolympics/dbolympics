WITH terminal_orders AS (
  SELECT o.id AS order_id, o.tenant_id AS tenant_id, t.industry AS industry, o.status AS status, o.placed_at AS placed_at
  FROM orders o
  JOIN tenants t ON t.id = o.tenant_id
  WHERE o.placed_at >= TIMESTAMP '2025-01-01' AND o.placed_at < TIMESTAMP '2026-01-01'
    AND o.status IN ('fulfilled','cancelled','refunded')
    AND t.industry IS NOT NULL
),
order_qty AS (
  SELECT oi.order_id AS order_id, SUM(oi.quantity) AS qty_ordered, SUM(oi.quantity_fulfilled) AS qty_fulfilled
  FROM order_items oi
  GROUP BY oi.order_id
),
order_shipment AS (
  SELECT f.order_id AS order_id,
         COUNT(s.id) AS shipment_count,
         SUM(CASE WHEN s.delivered_at IS NULL THEN 1 ELSE 0 END) AS undelivered_count,
         MAX(s.delivered_at) AS max_delivered_at
  FROM fulfillments f
  JOIN shipments s ON s.fulfillment_id = f.id
  GROUP BY f.order_id
),
order_flags AS (
  SELECT
    t0.order_id AS order_id,
    t0.tenant_id AS tenant_id,
    t0.industry AS industry,
    t0.status AS status,
    t0.placed_at AS placed_at,
    COALESCE(q.qty_ordered, 0) AS qty_ordered,
    COALESCE(q.qty_fulfilled, 0) AS qty_fulfilled,
    CASE WHEN COALESCE(q.qty_fulfilled,0) < COALESCE(q.qty_ordered,0) THEN 1 ELSE 0 END AS has_shortfall,
    CASE WHEN t0.status = 'fulfilled'
              AND s.shipment_count IS NOT NULL
              AND s.shipment_count > 0
              AND COALESCE(s.undelivered_count,0) = 0
         THEN 1 ELSE 0 END AS is_fully_delivered,
    s.max_delivered_at AS max_delivered_at
  FROM terminal_orders t0
  LEFT JOIN order_qty q ON q.order_id = t0.order_id
  LEFT JOIN order_shipment s ON s.order_id = t0.order_id
)
SELECT
  industry,
  COUNT(*) AS orders_placed_2025,
  100.0 * SUM(has_shortfall) / NULLIF(COUNT(*),0) AS pct_orders_with_fulfillment_shortfall,
  SUM(is_fully_delivered) AS orders_fully_delivered,
  AVG(CASE WHEN is_fully_delivered=1 THEN {{seconds_between(placed_at, max_delivered_at)}}/86400.0 END) AS avg_delivery_days,
  100.0 * SUM(CASE WHEN is_fully_delivered=1 AND max_delivered_at <= placed_at + INTERVAL '5' DAY THEN 1 ELSE 0 END) / NULLIF(SUM(is_fully_delivered),0) AS pct_within_5_days
FROM order_flags
GROUP BY industry
ORDER BY pct_orders_with_fulfillment_shortfall DESC NULLS FIRST, industry ASC NULLS LAST
