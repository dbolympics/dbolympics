SELECT
  s.carrier AS carrier,
  cd.month_label AS month_label,
  COUNT(*) AS shipment_count,
  AVG({{seconds_between(s.shipped_at, s.delivered_at)}} / 86400.0) FILTER (WHERE s.delivered_at IS NOT NULL) AS avg_delivery_days,
  100.0 * COUNT(*) FILTER (WHERE s.delivered_at IS NOT NULL AND s.delivered_at <= s.shipped_at + INTERVAL '3' DAY)
  / NULLIF(COUNT(*) FILTER (WHERE s.delivered_at IS NOT NULL), 0) AS pct_delivered_within_3_days
FROM shipments s
JOIN fulfillments f ON f.id = s.fulfillment_id
JOIN orders o ON o.id = f.order_id
JOIN tenants t ON t.id = o.tenant_id
JOIN calendar_days cd ON cd.calendar_date = CAST(s.shipped_at AS date)
WHERE t.name = 'Studio Vrij'
  AND s.carrier IN ('Lowlands Express', 'Polder Post')
  AND s.shipped_at >= DATE '2025-01-01'
  AND s.shipped_at < DATE '2026-01-01'
GROUP BY s.carrier, cd.month_label
ORDER BY s.carrier NULLS LAST, cd.month_label NULLS LAST
