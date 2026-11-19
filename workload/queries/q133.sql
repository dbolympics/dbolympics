WITH affected AS (
  SELECT DISTINCT jr.tenant_id AS tenant_id
  FROM job_runs jr
  JOIN jobs j ON jr.job_id = j.id
  WHERE j.handler = 'carts.remind'
    AND jr.status = 'failed'
    AND jr.queued_at >= DATE '2025-11-01' AND jr.queued_at < DATE '2025-12-01'
),
groups AS (
  SELECT t.id AS tenant_id,
    CASE WHEN a.tenant_id IS NOT NULL THEN 'Affected' ELSE 'Other' END AS group_name
  FROM tenants t
  LEFT JOIN affected a ON a.tenant_id = t.id
),
tenant_counts AS (
  SELECT group_name, COUNT(*) AS tenant_count
  FROM groups
  GROUP BY group_name
),
ticket_counts AS (
  SELECT g.group_name AS group_name,
    SUM(CASE WHEN tk.created_at >= DATE '2025-08-01' AND tk.created_at < DATE '2025-10-01' THEN 1 ELSE 0 END) AS baseline_tickets,
    SUM(CASE WHEN tk.created_at >= DATE '2025-11-01' AND tk.created_at < DATE '2026-01-01' THEN 1 ELSE 0 END) AS incident_tickets
  FROM groups g
  LEFT JOIN tickets tk ON tk.tenant_id = g.tenant_id
  GROUP BY g.group_name
)
SELECT
  tc.group_name AS group_name,
  tcn.tenant_count AS tenant_count,
  {{divide_decimal(CAST(tc.baseline_tickets AS numeric(18,6)), tcn.tenant_count)}} / ({{divide_decimal(61, 7.0)}}) AS avg_weekly_tickets_per_tenant_baseline,
  {{divide_decimal(CAST(tc.incident_tickets AS numeric(18,6)), tcn.tenant_count)}} / ({{divide_decimal(61, 7.0)}}) AS avg_weekly_tickets_per_tenant_incident,
  ((({{divide_decimal(CAST(tc.incident_tickets AS numeric(18,6)), tcn.tenant_count)}}) - ({{divide_decimal(CAST(tc.baseline_tickets AS numeric(18,6)), tcn.tenant_count)}}))
   / NULLIF({{divide_decimal(CAST(tc.baseline_tickets AS numeric(18,6)), tcn.tenant_count)}}, 0)) * 100 AS pct_change
FROM ticket_counts tc
JOIN tenant_counts tcn ON tcn.group_name = tc.group_name
ORDER BY tc.group_name NULLS LAST
