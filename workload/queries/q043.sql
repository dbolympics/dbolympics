SELECT
  {{year_month(o.placed_at)}} as month,
  SUM(CASE WHEN s.tenant_id = sv.id THEN 1 ELSE 0 END) as sv_shipments_delivered,
  AVG(CASE WHEN s.tenant_id = sv.id THEN {{divide_decimal({{seconds_between(o.placed_at, s.delivered_at)}}, 86400)}} END) as sv_avg_days_placed_to_delivered,
  {{divide_decimal(100.0 * SUM(CASE WHEN s.tenant_id = sv.id AND {{divide_decimal({{seconds_between(o.placed_at, s.delivered_at)}}, 86400)}} > 7 THEN 1 ELSE 0 END), NULLIF(SUM(CASE WHEN s.tenant_id = sv.id THEN 1 ELSE 0 END),0))}} as sv_pct_over_7_days,
  SUM(CASE WHEN s.tenant_id <> sv.id THEN 1 ELSE 0 END) as platform_shipments_delivered,
  AVG(CASE WHEN s.tenant_id <> sv.id THEN {{divide_decimal({{seconds_between(o.placed_at, s.delivered_at)}}, 86400)}} END) as platform_avg_days_placed_to_delivered,
  {{divide_decimal(100.0 * SUM(CASE WHEN s.tenant_id <> sv.id AND {{divide_decimal({{seconds_between(o.placed_at, s.delivered_at)}}, 86400)}} > 7 THEN 1 ELSE 0 END), NULLIF(SUM(CASE WHEN s.tenant_id <> sv.id THEN 1 ELSE 0 END),0))}} as platform_pct_over_7_days
FROM shipments s
JOIN fulfillments f ON f.id = s.fulfillment_id AND f.tenant_id = s.tenant_id
JOIN orders o ON o.id = f.order_id AND o.tenant_id = f.tenant_id
CROSS JOIN (SELECT id FROM tenants WHERE name = 'Studio Vrij') sv
WHERE s.delivered_at IS NOT NULL
  AND o.placed_at >= DATE '2025-01-01' AND o.placed_at < DATE '2026-01-01'
GROUP BY month
ORDER BY month NULLS LAST
