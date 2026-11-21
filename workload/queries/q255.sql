WITH base_tickets AS (
  SELECT
    t0.tenant_id AS tenant_id,
    t0.assignee_agent_id AS assignee_agent_id,
    t0.id AS ticket_id,
    t0.created_at AS created_at,
    t0.resolved_at AS resolved_at
  FROM tickets t0
  JOIN tenants t1 ON t1.id = t0.tenant_id
  WHERE t1.name IN ('Cragsley Outfitters', 'Marrowby & Vane', 'Studio Vrij')
    AND t0.assignee_agent_id IS NOT NULL
    AND t0.created_at >= DATE '2025-01-01'
    AND t0.created_at < DATE '2026-01-01'
)
SELECT
  t2.merchant_name AS merchant_name,
  t3.agent_display_name AS agent_display_name,
  COALESCE(t4.tickets_handled, 0) AS tickets_handled_2025,
  COALESCE(t5.avg_resolution_hours, 0) AS avg_resolution_hours_or_zero,
  COALESCE(t5.median_resolution_hours, 0) AS median_resolution_hours,
  COALESCE(t6.breach_rate_pct, 0) AS sla_breach_rate_pct
FROM (
  SELECT DISTINCT tenant_id, assignee_agent_id FROM base_tickets
) t0
JOIN (
  SELECT id AS tenant_id, name AS merchant_name FROM tenants
) t2 ON t2.tenant_id = t0.tenant_id
JOIN (
  SELECT id AS agent_id, display_name AS agent_display_name FROM support_agents
) t3 ON t3.agent_id = t0.assignee_agent_id
LEFT JOIN (
  SELECT tenant_id, assignee_agent_id, COUNT(*) AS tickets_handled
  FROM base_tickets
  GROUP BY tenant_id, assignee_agent_id
) t4 ON t4.tenant_id = t0.tenant_id AND t4.assignee_agent_id = t0.assignee_agent_id
LEFT JOIN (
  SELECT
    tenant_id,
    assignee_agent_id,
    AVG({{divide_decimal({{seconds_between(created_at, resolved_at)}}, 3600.0)}}) AS avg_resolution_hours,
    {{percentile_cont(0.5, {{divide_decimal({{seconds_between(created_at, resolved_at)}}, 3600.0)}})}} AS median_resolution_hours
  FROM base_tickets
  WHERE resolved_at IS NOT NULL
  GROUP BY tenant_id, assignee_agent_id
) t5 ON t5.tenant_id = t0.tenant_id AND t5.assignee_agent_id = t0.assignee_agent_id
LEFT JOIN (
  SELECT
    t7.tenant_id AS tenant_id,
    t7.assignee_agent_id AS assignee_agent_id,
    {{divide_decimal(100.0 * COUNT(DISTINCT CASE WHEN t8.ticket_id IS NOT NULL THEN t7.ticket_id END), COUNT(DISTINCT t7.ticket_id))}} AS breach_rate_pct
  FROM base_tickets t7
  LEFT JOIN sla_breaches t8 ON t8.ticket_id = t7.ticket_id
  GROUP BY t7.tenant_id, t7.assignee_agent_id
) t6 ON t6.tenant_id = t0.tenant_id AND t6.assignee_agent_id = t0.assignee_agent_id
ORDER BY t2.merchant_name ASC NULLS LAST, t5.avg_resolution_hours DESC NULLS LAST, t3.agent_display_name ASC NULLS LAST, t0.tenant_id ASC NULLS LAST, t0.assignee_agent_id ASC NULLS LAST
