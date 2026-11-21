SELECT carrier, orders_fully_delivered, avg_delivery_days, pct_within_5_days, share_of_orders_pct
FROM (
  SELECT
    carrier,
    orders_fully_delivered,
    avg_delivery_days,
    pct_within_5_days,
    share_of_orders_pct
  FROM (
    SELECT
      d.carrier AS carrier,
      COUNT(*) AS orders_fully_delivered,
      AVG(CAST(d.delivery_days AS NUMERIC(18,6))) AS avg_delivery_days,
      {{divide_decimal(100.0 * SUM(CASE WHEN d.delivery_days <= 5 THEN 1 ELSE 0 END), COUNT(*))}} AS pct_within_5_days,
      {{divide_decimal(100.0 * COUNT(*), (
  SELECT COUNT(*)
  FROM (
    SELECT o2.id AS order_id
    FROM orders o2
    JOIN fulfillments f2a ON f2a.order_id = o2.id
    JOIN shipments s2a ON s2a.fulfillment_id = f2a.id
    WHERE o2.status = 'fulfilled'
      AND o2.placed_at >= TIMESTAMP '2025-01-01 00:00:00'
      AND o2.placed_at < TIMESTAMP '2026-01-01 00:00:00'
      AND s2a.delivered_at IS NOT NULL
      AND (SELECT COUNT(*) FROM fulfillments ff WHERE ff.order_id = o2.id) = 1
      AND (SELECT COUNT(*) FROM shipments ss WHERE ss.fulfillment_id = f2a.id) = 1
  ) all_d
))}} AS share_of_orders_pct
    FROM (
      SELECT
        o.id AS order_id,
        s.carrier AS carrier,
        {{date_diff_days(o.placed_at, s.delivered_at)}} AS delivery_days
      FROM orders o
      JOIN fulfillments f ON f.order_id = o.id
      JOIN shipments s ON s.fulfillment_id = f.id
      WHERE o.status = 'fulfilled'
        AND o.placed_at >= TIMESTAMP '2025-01-01 00:00:00'
        AND o.placed_at < TIMESTAMP '2026-01-01 00:00:00'
        AND s.delivered_at IS NOT NULL
        AND (SELECT COUNT(*) FROM fulfillments f2 WHERE f2.order_id = o.id) = 1
        AND (SELECT COUNT(*) FROM shipments s2 WHERE s2.fulfillment_id = f.id) = 1
    ) d
    GROUP BY d.carrier
  ) per_carrier

  UNION ALL

  SELECT
    'ALL CARRIERS' AS carrier,
    orders_fully_delivered,
    avg_delivery_days,
    pct_within_5_days,
    100.0 AS share_of_orders_pct
  FROM (
    SELECT
      COUNT(*) AS orders_fully_delivered,
      AVG(CAST(delivery_days AS NUMERIC(18,6))) AS avg_delivery_days,
      {{divide_decimal(100.0 * SUM(CASE WHEN delivery_days <= 5 THEN 1 ELSE 0 END), COUNT(*))}} AS pct_within_5_days
    FROM (
      SELECT
        ({{date_diff_days(o.placed_at, s.delivered_at)}}) AS delivery_days
      FROM orders o
      JOIN fulfillments f ON f.order_id = o.id
      JOIN shipments s ON s.fulfillment_id = f.id
      WHERE o.status = 'fulfilled'
        AND o.placed_at >= TIMESTAMP '2025-01-01 00:00:00'
        AND o.placed_at < TIMESTAMP '2026-01-01 00:00:00'
        AND s.delivered_at IS NOT NULL
        AND (SELECT COUNT(*) FROM fulfillments f2 WHERE f2.order_id = o.id) = 1
        AND (SELECT COUNT(*) FROM shipments s2 WHERE s2.fulfillment_id = f.id) = 1
    ) all_orders
  ) totals
) combined
ORDER BY
  (CASE WHEN carrier = 'ALL CARRIERS' THEN 1 ELSE 0 END) NULLS LAST,
  orders_fully_delivered DESC NULLS FIRST,
  carrier ASC NULLS LAST
