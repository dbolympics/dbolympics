SELECT t.name AS tenant_name,
       CAST({{date_trunc('month', wd.created_at)}} AS date) AS month,
       COUNT(*) AS total_sync_deliveries,
       100.0 * COUNT(*) FILTER (WHERE wd.status IN ('pending','retrying')) / COUNT(*) AS pending_or_retrying_rate_pct
FROM webhook_deliveries wd
JOIN webhooks w ON w.id = wd.webhook_id
JOIN tenants t ON t.id = wd.tenant_id
WHERE t.name IN ('Brennquell Kaffee','Cragsley Outfitters','Ampfeld Elektronik','Marrowby & Vane')
  AND wd.created_at >= DATE '2025-01-01' AND wd.created_at < DATE '2026-01-01'
  AND (w.name ILIKE '%ERP%sync%' OR w.name ILIKE '%WMS%sync%' OR w.name ILIKE '%ACCOUNTING%sync%')
GROUP BY t.name, {{date_trunc('month', wd.created_at)}}
ORDER BY t.name ASC NULLS LAST, {{date_trunc('month', wd.created_at)}} ASC NULLS LAST
