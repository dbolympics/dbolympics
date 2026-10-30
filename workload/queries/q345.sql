SELECT
  {{date_trunc('hour', checked_at)}} AS checked_hour,
  component,
  count(*) AS total_checks,
  count(*) FILTER (WHERE is_healthy = false) AS unhealthy_checks,
  100.0 * count(*) FILTER (WHERE is_healthy = false) / count(*) AS unhealthy_rate_pct,
  avg(cast(latency_ms as numeric(18,6))) AS avg_latency_ms
FROM system_health_checks
WHERE checked_at >= DATE '2025-11-01'
  AND checked_at < DATE '2026-01-01'
  AND component IN ('checkout', 'storefront')
GROUP BY {{date_trunc('hour', checked_at)}}, component
HAVING 100.0 * count(*) FILTER (WHERE is_healthy = false) / count(*) >= 50
ORDER BY checked_hour ASC NULLS LAST, component ASC NULLS LAST
