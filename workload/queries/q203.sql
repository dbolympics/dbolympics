WITH ticket_window AS (
  SELECT
    t.id AS id,
    t.tenant_id AS tenant_id,
    t.channel AS channel,
    CASE WHEN t.assignee_agent_id IS NULL THEN 'Unassigned' ELSE 'Assigned' END AS assignment_status,
    t.created_at AS created_at,
    t.first_response_at AS first_response_at,
    t.resolved_at AS resolved_at
  FROM tickets t
  WHERE t.created_at >= DATE '2025-01-01'
    AND t.created_at < DATE '2026-01-01'
),
ticket_breach_flags AS (
  SELECT
    tw.id AS ticket_id,
    MAX(CASE WHEN sb.breach_kind = 'first_response' THEN 1 ELSE 0 END) AS first_response_breached,
    MAX(CASE WHEN sb.breach_kind = 'resolution' THEN 1 ELSE 0 END) AS resolution_breached
  FROM ticket_window tw
  LEFT JOIN sla_breaches sb
    ON sb.ticket_id = tw.id AND sb.tenant_id = tw.tenant_id
  GROUP BY tw.id
),
ticket_metrics AS (
  SELECT
    tw.id AS id,
    tw.channel AS channel,
    tw.assignment_status AS assignment_status,
    {{divide_decimal({{seconds_between(tw.created_at, tw.first_response_at)}}, 60.0)}} AS first_response_minutes,
    {{divide_decimal({{seconds_between(tw.created_at, tw.resolved_at)}}, 60.0)}} AS resolution_minutes,
    bf.first_response_breached AS first_response_breached,
    bf.resolution_breached AS resolution_breached
  FROM ticket_window tw
  JOIN ticket_breach_flags bf ON bf.ticket_id = tw.id
)
SELECT
  channel,
  assignment_status,
  COUNT(*) AS ticket_count,
  AVG(first_response_minutes) AS avg_first_response_minutes,
  AVG(resolution_minutes) AS avg_resolution_minutes,
  100.0 * AVG(CAST(first_response_breached AS NUMERIC(18,6))) AS first_response_breach_rate,
  100.0 * AVG(CAST(resolution_breached AS NUMERIC(18,6))) AS resolution_breach_rate
FROM ticket_metrics
GROUP BY channel, assignment_status
ORDER BY avg_resolution_minutes DESC NULLS FIRST, channel NULLS LAST, assignment_status NULLS LAST
