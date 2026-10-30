SELECT 
  {{date_trunc('hour', checked_at)}} + (CAST(floor(extract(minute from checked_at)/30) AS int) * interval '30 minute') AS interval_start,
  component,
  count(*) AS total_checks,
  count(*) FILTER (WHERE is_healthy = false) AS unhealthy_checks,
  100.0 * count(*) FILTER (WHERE is_healthy = false) / count(*) AS unhealthy_rate_pct,
  avg(cast(latency_ms as numeric(18,6))) AS avg_latency_ms
FROM system_health_checks
WHERE checked_at >= timestamp '2025-11-28 13:00:00' AND checked_at < timestamp '2025-11-28 17:00:00'
  AND component IN ('checkout','storefront')
GROUP BY 1,2
ORDER BY interval_start ASC NULLS LAST, component ASC NULLS LAST
