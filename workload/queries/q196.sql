WITH group_names AS (
  SELECT DISTINCT name AS agent_group_name
  FROM agent_groups
),

ticket_window AS (
  SELECT
    t.id AS id,
    t.agent_group_id AS agent_group_id,
    t.tenant_id AS tenant_id,
    ag.name AS group_name,
    t.status AS status,
    t.assignee_agent_id AS assignee_agent_id,
    t.created_at AS created_at,
    t.first_response_at AS first_response_at,
    t.resolved_at AS resolved_at
  FROM tickets t
  LEFT JOIN agent_groups ag
    ON ag.id = t.agent_group_id AND ag.tenant_id = t.tenant_id
  WHERE t.created_at >= TIMESTAMP '2025-01-01'
    AND t.created_at < TIMESTAMP '2026-01-01'
),

ticket_metrics AS (
  SELECT
    COALESCE(group_name, 'Unassigned queue') AS agent_group_name,
    COUNT(*) AS ticket_count,
    COUNT(*) FILTER (WHERE status NOT IN ('solved','closed')) AS open_ticket_count,
    COUNT(*) FILTER (WHERE assignee_agent_id IS NULL) AS unassigned_ticket_count,
    AVG({{divide_decimal({{seconds_between(created_at, first_response_at)}}, 60.0)}})
      FILTER (WHERE first_response_at IS NOT NULL) AS avg_first_response_minutes,
    AVG({{divide_decimal({{seconds_between(created_at, resolved_at)}}, 60.0)}})
      FILTER (WHERE resolved_at IS NOT NULL) AS avg_resolution_minutes
  FROM ticket_window
  GROUP BY COALESCE(group_name, 'Unassigned queue')
),

agent_counts AS (
  SELECT
    ag.name AS agent_group_name,
    COUNT(DISTINCT CAST(agm.tenant_id AS text) || ':' || CAST(agm.support_agent_id AS text)) AS agent_count
  FROM agent_group_members agm
  JOIN agent_groups ag
    ON ag.id = agm.agent_group_id AND ag.tenant_id = agm.tenant_id
  GROUP BY ag.name
),

all_rows AS (
  SELECT agent_group_name FROM group_names
  UNION
  SELECT 'Unassigned queue'
)

SELECT
  r.agent_group_name AS agent_group_name,
  COALESCE(tm.ticket_count, 0) AS ticket_count,
  COALESCE(tm.open_ticket_count, 0) AS open_ticket_count,
  ac.agent_count AS agent_count,
  {{divide_decimal(CAST(COALESCE(tm.ticket_count,0) AS numeric(18,6)), NULLIF(ac.agent_count,0))}} AS tickets_per_agent,
  {{divide_decimal(100.0 * COALESCE(tm.unassigned_ticket_count,0), NULLIF(tm.ticket_count,0))}} AS pct_unassigned,
  tm.avg_first_response_minutes AS avg_first_response_minutes,
  tm.avg_resolution_minutes AS avg_resolution_minutes
FROM all_rows r
LEFT JOIN ticket_metrics tm ON tm.agent_group_name = r.agent_group_name
LEFT JOIN agent_counts ac ON ac.agent_group_name = r.agent_group_name
ORDER BY
  CASE WHEN r.agent_group_name = 'Unassigned queue' THEN 1 ELSE 0 END NULLS LAST,
  COALESCE(tm.ticket_count,0) DESC NULLS FIRST,
  r.agent_group_name NULLS LAST
