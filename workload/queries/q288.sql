SELECT
  cd.month_label AS month,
  COUNT(*) AS carts_created,
  100.0 * COUNT(*) FILTER (WHERE c.status = 'converted') / COUNT(*) AS overall_conversion_pct,
  100.0 * COUNT(*) FILTER (WHERE COALESCE(c.converted_at, c.abandoned_at, c.expires_at) <= c.created_at + INTERVAL '1 hour') / COUNT(*) AS pct_resolved_within_1_hour,
  100.0 * COUNT(*) FILTER (WHERE COALESCE(c.converted_at, c.abandoned_at, c.expires_at) > c.created_at + INTERVAL '1 hour' AND COALESCE(c.converted_at, c.abandoned_at, c.expires_at) <= c.created_at + INTERVAL '7 days') / COUNT(*) AS pct_resolved_1_7_days,
  {{percentile_cont_filter(0.5, {{seconds_between(c.created_at, c.converted_at)}}/86400.0, c.status = 'converted')}} AS median_days_to_convert
FROM carts c
JOIN tenants t ON t.id = c.tenant_id
JOIN calendar_days cd ON cd.calendar_date = CAST(c.created_at AS date)
WHERE t.name IN ('Kibblewick','Studio Vrij','Petalcourt Beauty','Marrowby & Vane','Cragsley Outfitters','Ampfeld Elektronik')
  AND c.created_at >= DATE '2025-01-01' AND c.created_at < DATE '2026-01-01'
GROUP BY cd.month_label
ORDER BY cd.month_label NULLS LAST
