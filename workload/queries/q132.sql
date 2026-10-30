SELECT
  CAST({{date_trunc('month', created_at)}} AS date) AS month,
  count(*) AS total_deliveries,
  count(*) FILTER (WHERE status = 'success') AS success_count,
  100.0 * count(*) FILTER (WHERE status = 'success') / count(*) AS success_rate_pct,
  count(*) FILTER (WHERE status = 'failed') AS failed_count,
  100.0 * count(*) FILTER (WHERE status = 'failed') / count(*) AS failure_rate_pct,
  avg(cast(duration_ms as numeric(18,6))) FILTER (WHERE duration_ms IS NOT NULL) AS avg_duration_ms,
  count(DISTINCT webhook_id) AS distinct_webhooks
FROM webhook_deliveries
WHERE created_at >= DATE '2025-01-01' AND created_at < DATE '2026-01-01'
GROUP BY {{date_trunc('month', created_at)}}
ORDER BY month ASC NULLS LAST
