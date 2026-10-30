SELECT
  {{date_trunc('hour', checked_at)}} AS hour,
  component,
  count(*) AS total_checks,
  count(*) FILTER (WHERE is_healthy = false) AS unhealthy_checks,
  100.0 * count(*) FILTER (WHERE is_healthy = false) / count(*) AS unhealthy_rate_pct,
  avg(cast(latency_ms as numeric(18,6))) AS avg_latency_ms
FROM system_health_checks
WHERE checked_at >= TIMESTAMP '2025-11-28 12:00:00'
  AND checked_at < TIMESTAMP '2025-11-28 18:00:00'
GROUP BY 1, 2
ORDER BY hour ASC NULLS LAST, component ASC NULLS LAST
