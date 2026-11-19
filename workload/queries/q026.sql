SELECT
  t.name AS tenant_name,
  t.industry AS industry,
  d.orders_delivered AS orders_delivered,
  d.avg_delivery_days AS avg_delivery_days,
  d.median_delivery_days AS median_delivery_days,
  d.p90_delivery_days AS p90_delivery_days,
  d.pct_within_5_days AS pct_within_5_days
FROM tenants t
JOIN (
  SELECT
    o.tenant_id AS tenant_id,
    COUNT(*) AS orders_delivered,
    AVG({{divide_decimal({{seconds_between(o.placed_at, o.delivered_at)}}, 86400.0)}}) AS avg_delivery_days,
    {{percentile_cont(0.5, {{divide_decimal({{seconds_between(o.placed_at, o.delivered_at)}}, 86400.0)}})}} AS median_delivery_days,
    {{percentile_cont(0.9, {{divide_decimal({{seconds_between(o.placed_at, o.delivered_at)}}, 86400.0)}})}} AS p90_delivery_days,
    AVG(CASE WHEN {{divide_decimal({{seconds_between(o.placed_at, o.delivered_at)}}, 86400.0)}} <= 5 THEN 1.0 ELSE 0.0 END) AS pct_within_5_days
  FROM (
    SELECT
      ord.id AS id,
      ord.tenant_id AS tenant_id,
      ord.placed_at AS placed_at,
      (SELECT MAX(s.delivered_at)
       FROM fulfillments f
       JOIN shipments s ON s.fulfillment_id = f.id
       WHERE f.order_id = ord.id) AS delivered_at
    FROM orders ord
    WHERE ord.status = 'fulfilled'
      AND ord.placed_at >= DATE '2025-01-01'
      AND ord.placed_at < DATE '2026-01-01'
      AND EXISTS (
        SELECT 1 FROM fulfillments f JOIN shipments s ON s.fulfillment_id = f.id
        WHERE f.order_id = ord.id
      )
      AND NOT EXISTS (
        SELECT 1 FROM fulfillments f JOIN shipments s ON s.fulfillment_id = f.id
        WHERE f.order_id = ord.id AND s.delivered_at IS NULL
      )
  ) o
  GROUP BY o.tenant_id
  HAVING COUNT(*) >= 50
) d ON d.tenant_id = t.id
ORDER BY d.orders_delivered DESC NULLS FIRST, t.name ASC NULLS LAST, t.id ASC NULLS LAST
{{fetch_first(50)}}
