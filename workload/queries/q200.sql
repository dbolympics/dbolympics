WITH ticket_agg AS (
  SELECT tenant_id, agent_group_id,
    COUNT(*) AS ticket_count,
    COUNT(*) FILTER (WHERE assignee_agent_id IS NULL) AS unassigned_count,
    AVG({{divide_decimal({{seconds_between(created_at, first_response_at)}}, 60.0)}}) FILTER (WHERE first_response_at IS NOT NULL) AS avg_first_response_minutes,
    AVG({{divide_decimal({{seconds_between(created_at, resolved_at)}}, 60.0)}}) FILTER (WHERE resolved_at IS NOT NULL) AS avg_resolution_minutes
  FROM tickets
  WHERE agent_group_id IS NOT NULL
    AND created_at >= DATE '2025-01-01'
    AND created_at < DATE '2026-01-01'
  GROUP BY tenant_id, agent_group_id
),
breach_agg AS (
  SELECT t.tenant_id AS tenant_id, t.agent_group_id AS agent_group_id,
    COUNT(DISTINCT sb.ticket_id) AS resolution_breach_count
  FROM tickets t
  JOIN sla_breaches sb ON sb.ticket_id = t.id AND sb.tenant_id = t.tenant_id
  WHERE t.agent_group_id IS NOT NULL
    AND t.created_at >= DATE '2025-01-01'
    AND t.created_at < DATE '2026-01-01'
    AND sb.breach_kind = 'resolution'
  GROUP BY t.tenant_id, t.agent_group_id
),
agent_counts AS (
  SELECT tenant_id, agent_group_id, COUNT(DISTINCT support_agent_id) AS agent_count
  FROM agent_group_members
  GROUP BY tenant_id, agent_group_id
)
SELECT
  ten.name AS tenant_name,
  ag.name AS agent_group_name,
  ta.ticket_count AS ticket_count,
  COALESCE(ac.agent_count,0) AS agent_count,
  {{divide_decimal(CAST(ta.ticket_count AS numeric(18,6)), NULLIF(ac.agent_count,0))}} AS tickets_per_agent,
  {{divide_decimal(100.0 * ta.unassigned_count, NULLIF(ta.ticket_count,0))}} AS pct_unassigned,
  ta.avg_first_response_minutes AS avg_first_response_minutes,
  ta.avg_resolution_minutes AS avg_resolution_minutes,
  {{divide_decimal(100.0 * COALESCE(ba.resolution_breach_count,0), NULLIF(ta.ticket_count,0))}} AS resolution_breach_rate
FROM ticket_agg ta
JOIN tenants ten ON ten.id = ta.tenant_id
JOIN agent_groups ag ON ag.id = ta.agent_group_id
LEFT JOIN agent_counts ac ON ac.tenant_id = ta.tenant_id AND ac.agent_group_id = ta.agent_group_id
LEFT JOIN breach_agg ba ON ba.tenant_id = ta.tenant_id AND ba.agent_group_id = ta.agent_group_id
ORDER BY ta.ticket_count DESC NULLS FIRST, ten.name NULLS LAST, ag.name NULLS LAST, ta.tenant_id NULLS LAST, ta.agent_group_id NULLS LAST
{{fetch_first(20)}}
