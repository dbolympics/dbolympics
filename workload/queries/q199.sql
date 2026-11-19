SELECT
  tenant_name,
  ticket_count,
  pct_of_total_tickets AS pct_of_total_tickets,
  sum(pct_of_total_tickets) OVER (ORDER BY ticket_count DESC NULLS FIRST, tenant_name NULLS LAST) AS cumulative_pct_of_total_tickets,
  first_response_breach_rate AS first_response_breach_rate,
  resolution_breach_rate AS resolution_breach_rate,
  avg_resolution_minutes AS avg_resolution_minutes,
  agent_count,
  total_tenants_with_tickets
FROM (
  SELECT
    t.name AS tenant_name,
    tk.tenant_id AS tenant_id,
    tk.ticket_count AS ticket_count,
    {{divide_decimal(100.0 * tk.ticket_count, tot.total_tickets)}} AS pct_of_total_tickets,
    {{divide_decimal(100.0 * coalesce(frb.breach_count, 0), nullif(tk.sla_ticket_count, 0))}} AS first_response_breach_rate,
    {{divide_decimal(100.0 * coalesce(rb.breach_count, 0), nullif(tk.sla_ticket_count, 0))}} AS resolution_breach_rate,
    tk.avg_resolution_minutes AS avg_resolution_minutes,
    (SELECT count(DISTINCT sa.id) FROM support_agents sa WHERE sa.tenant_id = tk.tenant_id) AS agent_count,
    tot.total_tickets AS total_tickets,
    tnt.total_tenants_with_tickets AS total_tenants_with_tickets
  FROM (
    SELECT
      tenant_id,
      count(*) AS ticket_count,
      count(*) FILTER (WHERE sla_policy_id IS NOT NULL) AS sla_ticket_count,
      avg({{divide_decimal({{seconds_between(created_at, resolved_at)}}, 60.0)}}) FILTER (WHERE resolved_at IS NOT NULL) AS avg_resolution_minutes
    FROM tickets
    WHERE created_at >= timestamp '2025-01-01' AND created_at < timestamp '2026-01-01'
    GROUP BY tenant_id
  ) tk
  JOIN tenants t ON t.id = tk.tenant_id
  CROSS JOIN (
    SELECT count(*) AS total_tickets
    FROM tickets
    WHERE created_at >= timestamp '2025-01-01' AND created_at < timestamp '2026-01-01'
  ) tot
  CROSS JOIN (
    SELECT count(DISTINCT tenant_id) AS total_tenants_with_tickets
    FROM tickets
    WHERE created_at >= timestamp '2025-01-01' AND created_at < timestamp '2026-01-01'
  ) tnt
  LEFT JOIN (
    SELECT sb.tenant_id AS tenant_id, count(*) AS breach_count
    FROM sla_breaches sb
    JOIN tickets tk2 ON tk2.id = sb.ticket_id
    WHERE sb.breach_kind = 'first_response'
      AND tk2.created_at >= timestamp '2025-01-01' AND tk2.created_at < timestamp '2026-01-01'
      AND tk2.sla_policy_id IS NOT NULL
    GROUP BY sb.tenant_id
  ) frb ON frb.tenant_id = tk.tenant_id
  LEFT JOIN (
    SELECT sb.tenant_id AS tenant_id, count(*) AS breach_count
    FROM sla_breaches sb
    JOIN tickets tk3 ON tk3.id = sb.ticket_id
    WHERE sb.breach_kind = 'resolution'
      AND tk3.created_at >= timestamp '2025-01-01' AND tk3.created_at < timestamp '2026-01-01'
      AND tk3.sla_policy_id IS NOT NULL
    GROUP BY sb.tenant_id
  ) rb ON rb.tenant_id = tk.tenant_id
) x
ORDER BY ticket_count DESC NULLS FIRST, tenant_name NULLS LAST, tenant_id NULLS LAST
{{fetch_first(30)}}
