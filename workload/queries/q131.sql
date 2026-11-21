WITH affected AS (
  SELECT DISTINCT jr.tenant_id AS tenant_id
  FROM job_runs jr
  JOIN jobs j ON j.id = jr.job_id
  WHERE j.handler = 'carts.remind'
    AND jr.status = 'failed'
    AND jr.queued_at >= TIMESTAMP '2025-11-01'
    AND jr.queued_at < TIMESTAMP '2025-12-01'
),
tenant_counts AS (
  SELECT COUNT(*) AS total_tenants
  FROM tenants
  WHERE status IN ('trial','active','past_due','suspended','churned')
),
ticket_weeks AS (
  SELECT cd.week_start AS week_start,
         t.tenant_id AS tenant_id,
         CASE WHEN t.tenant_id IN (SELECT tenant_id FROM affected) THEN 1 ELSE 0 END AS is_affected
  FROM tickets t
  JOIN calendar_days cd ON cd.calendar_date = CAST(t.created_at AS DATE)
  WHERE t.created_at >= TIMESTAMP '2025-11-01' AND t.created_at < TIMESTAMP '2026-01-01'
)
SELECT
  week_start,
  COUNT(*) FILTER (WHERE is_affected = 1) AS tickets_affected_tenants,
  {{divide_decimal(COUNT(*) FILTER (WHERE is_affected = 1), 10.0)}} AS avg_tickets_per_affected_tenant,
  COUNT(*) FILTER (WHERE is_affected = 0) AS tickets_other_tenants,
  {{divide_decimal(CAST(COUNT(*) FILTER (WHERE is_affected = 0) AS NUMERIC(18,6)), (SELECT (total_tenants - 10) FROM tenant_counts))}} AS avg_tickets_per_other_tenant
FROM ticket_weeks
GROUP BY week_start
ORDER BY week_start NULLS LAST
