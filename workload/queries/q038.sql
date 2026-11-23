SELECT 
  t_tenant.name AS merchant_name,
  t_counts.tickets_created AS tickets_created,
  t_fr.avg_first_response_hours AS avg_first_response_hours,
  t_fr.median_first_response_hours AS median_first_response_hours,
  t_res.avg_resolution_hours AS avg_resolution_hours,
  t_res.median_resolution_hours AS median_resolution_hours,
  {{divide_decimal(CAST(COALESCE(t_breach.breached_tickets, 0) AS numeric(18,6)), CAST(t_counts.tickets_created AS numeric(18,6)))}} * 100.0 AS sla_breach_rate_pct
FROM (
  SELECT t0.tenant_id AS tenant_id, COUNT(*) AS tickets_created
  FROM tickets t0
  WHERE t0.created_at >= DATE '2025-01-01' AND t0.created_at < DATE '2026-01-01'
  GROUP BY t0.tenant_id
) t_counts
JOIN tenants t_tenant
  ON t_tenant.id = t_counts.tenant_id
LEFT JOIN (
  SELECT t0.tenant_id AS tenant_id,
    AVG({{divide_decimal({{seconds_between(t0.created_at, t0.first_response_at)}}, 3600.0)}}) AS avg_first_response_hours,
    {{percentile_cont(0.5, {{divide_decimal({{seconds_between(t0.created_at, t0.first_response_at)}}, 3600.0)}})}} AS median_first_response_hours
  FROM tickets t0
  WHERE t0.created_at >= DATE '2025-01-01' AND t0.created_at < DATE '2026-01-01'
    AND t0.first_response_at IS NOT NULL
  GROUP BY t0.tenant_id
) t_fr
  ON t_fr.tenant_id = t_counts.tenant_id
LEFT JOIN (
  SELECT t0.tenant_id AS tenant_id,
    AVG({{divide_decimal({{seconds_between(t0.created_at, t0.resolved_at)}}, 3600.0)}}) AS avg_resolution_hours,
    {{percentile_cont(0.5, {{divide_decimal({{seconds_between(t0.created_at, t0.resolved_at)}}, 3600.0)}})}} AS median_resolution_hours
  FROM tickets t0
  WHERE t0.created_at >= DATE '2025-01-01' AND t0.created_at < DATE '2026-01-01'
    AND t0.resolved_at IS NOT NULL
  GROUP BY t0.tenant_id
) t_res
  ON t_res.tenant_id = t_counts.tenant_id
LEFT JOIN (
  SELECT t0.tenant_id AS tenant_id, COUNT(DISTINCT t0.id) AS breached_tickets
  FROM tickets t0
  JOIN sla_breaches t1 ON t1.ticket_id = t0.id
  WHERE t0.created_at >= DATE '2025-01-01' AND t0.created_at < DATE '2026-01-01'
  GROUP BY t0.tenant_id
) t_breach
  ON t_breach.tenant_id = t_counts.tenant_id
WHERE t_counts.tickets_created >= 20
ORDER BY t_counts.tickets_created DESC NULLS FIRST, t_tenant.name ASC NULLS LAST, t_tenant.id NULLS LAST
{{fetch_first(50)}}
