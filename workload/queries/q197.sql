WITH base AS (
  SELECT t.id AS id, t.agent_group_id AS agent_group_id, COALESCE(ag.name, 'Unassigned queue') AS agent_group_name,
         t.created_at AS created_at, t.first_response_at AS first_response_at, t.resolved_at AS resolved_at
  FROM tickets t
  LEFT JOIN agent_groups ag ON ag.id = t.agent_group_id
  WHERE t.created_at >= DATE '2025-01-01' AND t.created_at < DATE '2026-01-01'
    AND t.sla_policy_id IS NOT NULL
),
ticket_stats AS (
  SELECT agent_group_id, agent_group_name,
         COUNT(*) AS ticket_count_with_sla,
         AVG({{divide_decimal({{seconds_between(created_at, first_response_at)}}, 60.0)}}) FILTER (WHERE first_response_at IS NOT NULL) AS avg_first_response_minutes,
         AVG({{divide_decimal({{seconds_between(created_at, resolved_at)}}, 60.0)}}) FILTER (WHERE resolved_at IS NOT NULL) AS avg_resolution_minutes
  FROM base
  GROUP BY agent_group_id, agent_group_name
),
breach_join AS (
  SELECT base.agent_group_id AS agent_group_id, base.agent_group_name AS agent_group_name, sb.ticket_id AS ticket_id, sb.breach_kind AS breach_kind, sb.minutes_over AS minutes_over
  FROM base
  JOIN sla_breaches sb ON sb.ticket_id = base.id
),
breach_stats AS (
  SELECT agent_group_id, agent_group_name,
    COUNT(DISTINCT ticket_id) FILTER (WHERE breach_kind = 'first_response') AS fr_breach_tickets,
    COUNT(DISTINCT ticket_id) FILTER (WHERE breach_kind = 'resolution') AS res_breach_tickets,
    AVG(CAST(minutes_over AS NUMERIC(18,6))) FILTER (WHERE breach_kind = 'first_response') AS avg_minutes_over_first_response,
    AVG(CAST(minutes_over AS NUMERIC(18,6))) FILTER (WHERE breach_kind = 'resolution') AS avg_minutes_over_resolution
  FROM breach_join
  GROUP BY agent_group_id, agent_group_name
)
SELECT
  ts.agent_group_name AS agent_group_name,
  ts.ticket_count_with_sla AS ticket_count_with_sla,
  {{divide_decimal(100.0 * COALESCE(bs.fr_breach_tickets, 0), ts.ticket_count_with_sla)}} AS first_response_breach_rate,
  {{divide_decimal(100.0 * COALESCE(bs.res_breach_tickets, 0), ts.ticket_count_with_sla)}} AS resolution_breach_rate,
  bs.avg_minutes_over_first_response AS avg_minutes_over_first_response,
  bs.avg_minutes_over_resolution AS avg_minutes_over_resolution,
  ts.avg_first_response_minutes AS avg_first_response_minutes,
  ts.avg_resolution_minutes AS avg_resolution_minutes
FROM ticket_stats ts
LEFT JOIN breach_stats bs ON bs.agent_group_id IS NOT DISTINCT FROM ts.agent_group_id
ORDER BY
  (ts.agent_group_name = 'Unassigned queue') ASC NULLS LAST,
  resolution_breach_rate DESC NULLS LAST,
  ts.agent_group_name ASC NULLS LAST,
  ts.agent_group_id NULLS LAST
