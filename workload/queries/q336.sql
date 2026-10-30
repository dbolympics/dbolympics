SELECT
  t0.month_start AS month,
  t0.total_sync_deliveries AS total_sync_deliveries,
  100.0 * t0.success_count / NULLIF(t0.total_sync_deliveries,0) AS success_rate_pct,
  100.0 * t0.failed_count / NULLIF(t0.total_sync_deliveries,0) AS failed_rate_pct,
  100.0 * t0.pending_retrying_count / NULLIF(t0.total_sync_deliveries,0) AS pending_or_retrying_rate_pct
FROM (
  SELECT
    {{date_trunc('month', wd.created_at)}} AS month_start,
    COUNT(*) AS total_sync_deliveries,
    SUM(CASE WHEN wd.status = 'success' THEN 1 ELSE 0 END) AS success_count,
    SUM(CASE WHEN wd.status = 'failed' THEN 1 ELSE 0 END) AS failed_count,
    SUM(CASE WHEN wd.status IN ('pending','retrying') THEN 1 ELSE 0 END) AS pending_retrying_count
  FROM webhook_deliveries wd
  JOIN webhooks wh ON wh.id = wd.webhook_id
  WHERE wh.name IN ('ERP sync','WMS sync','ACCOUNTING sync')
    AND wd.created_at >= DATE '2025-01-01'
    AND wd.created_at < DATE '2026-01-01'
  GROUP BY {{date_trunc('month', wd.created_at)}}
) t0
ORDER BY t0.month_start ASC NULLS LAST
