SELECT
  t.name AS tenant_name,
  s.carrier AS carrier,
  count(*) AS shipment_count,
  100.0 * count(*) / sum(count(*)) over (partition by t.name) AS pct_of_tenant_shipments,
  avg({{seconds_between(s.shipped_at, s.delivered_at)}} / 86400.0) filter (where s.delivered_at is not null and s.shipped_at is not null) AS avg_delivery_days,
  100.0 * count(*) filter (where s.delivered_at is not null and s.shipped_at is not null and s.delivered_at <= s.shipped_at + INTERVAL '3' DAY)
  / nullif(count(*) filter (where s.delivered_at is not null and s.shipped_at is not null), 0) AS pct_delivered_within_3_days
FROM shipments s
JOIN tenants t ON t.id = s.tenant_id
WHERE t.name IN ('Marrowby & Vane', 'Studio Vrij', 'Cragsley Outfitters')
  AND s.shipped_at >= timestamp '2025-01-01'
  AND s.shipped_at < timestamp '2026-01-01'
GROUP BY t.name, s.carrier
ORDER BY t.name NULLS LAST, shipment_count DESC NULLS FIRST, s.carrier NULLS LAST
