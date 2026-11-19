WITH affected AS (
  SELECT DISTINCT jr.tenant_id AS tenant_id
  FROM job_runs jr
  JOIN jobs j ON j.id = jr.job_id
  WHERE j.name = 'carts.remind'
    AND jr.status = 'failed'
    AND jr.started_at >= DATE '2025-11-01'
    AND jr.started_at < DATE '2025-12-01'
)
SELECT
  CASE WHEN wd.tenant_id IN (SELECT tenant_id FROM affected) THEN 'Affected' ELSE 'Other' END AS group_name,
  COUNT(DISTINCT wd.tenant_id) AS tenant_count,
  COUNT(*) AS total_deliveries_2025,
  {{divide_decimal(100.0 * SUM(CASE WHEN wd.status = 'success' THEN 1 ELSE 0 END), COUNT(*))}} AS success_rate_pct,
  {{divide_decimal(100.0 * SUM(CASE WHEN wd.status = 'failed' THEN 1 ELSE 0 END), COUNT(*))}} AS failed_rate_pct,
  {{divide_decimal(100.0 * SUM(CASE WHEN wd.status IN ('pending', 'retrying') THEN 1 ELSE 0 END), COUNT(*))}} AS pending_or_retrying_rate_pct
FROM webhook_deliveries wd
JOIN webhooks w ON w.id = wd.webhook_id
WHERE wd.created_at >= TIMESTAMP '2025-01-01 00:00:00'
  AND wd.created_at < TIMESTAMP '2026-01-01 00:00:00'
GROUP BY group_name
ORDER BY group_name NULLS LAST
