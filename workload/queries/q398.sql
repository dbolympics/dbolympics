WITH target_tenants AS (
  SELECT id AS tenant_id, name AS tenant_name
  FROM tenants
  WHERE name IN ('Cragsley Outfitters','Marrowby & Vane','Studio Vrij','Brennquell Kaffee','Grind Collective','Petalcourt Beauty')
),
tickets_2025 AS (
  SELECT t.id AS id, t.tenant_id AS tenant_id, t.priority AS priority, t.created_at AS created_at, t.resolved_at AS resolved_at
  FROM tickets t
  JOIN target_tenants tt ON tt.tenant_id = t.tenant_id
  WHERE t.created_at >= DATE '2025-01-01' AND t.created_at < DATE '2026-01-01'
),
ticket_counts AS (
  SELECT tenant_id, COUNT(*) AS ticket_count
  FROM tickets_2025
  GROUP BY tenant_id
),
message_counts AS (
  SELECT t.tenant_id AS tenant_id, COUNT(tm.id) AS message_count
  FROM tickets_2025 t
  JOIN ticket_messages tm ON tm.ticket_id = t.id
  GROUP BY t.tenant_id
),
agent_counts AS (
  SELECT tenant_id, COUNT(DISTINCT id) AS agent_count
  FROM support_agents
  WHERE tenant_id IN (SELECT tenant_id FROM target_tenants)
  GROUP BY tenant_id
),
priority_counts AS (
  SELECT tenant_id,
    SUM(CASE WHEN priority IN ('high','urgent') THEN 1 ELSE 0 END) AS high_urgent_count
  FROM tickets_2025
  GROUP BY tenant_id
),
resolution_stats AS (
  SELECT tenant_id,
    AVG({{divide_decimal({{seconds_between(created_at, resolved_at)}}, 60.0)}}) AS avg_resolution_minutes
  FROM tickets_2025
  WHERE resolved_at IS NOT NULL
  GROUP BY tenant_id
),
breach_counts AS (
  SELECT t.tenant_id AS tenant_id, COUNT(DISTINCT sb.ticket_id) AS breach_count
  FROM tickets_2025 t
  JOIN sla_breaches sb ON sb.ticket_id = t.id AND sb.breach_kind = 'resolution'
  GROUP BY t.tenant_id
)
SELECT
  tt.tenant_name AS tenant_name,
  tc.ticket_count AS ticket_count,
  COALESCE(ac.agent_count, 0) AS agent_count,
  {{divide_decimal(CAST(tc.ticket_count AS numeric(18,6)), NULLIF(ac.agent_count, 0))}} AS tickets_per_agent,
  {{divide_decimal(CAST(COALESCE(mc.message_count, 0) AS numeric(18,6)), NULLIF(tc.ticket_count, 0))}} AS avg_messages_per_ticket,
  {{divide_decimal(100.0 * COALESCE(pc.high_urgent_count, 0), NULLIF(tc.ticket_count, 0))}} AS pct_high_or_urgent_priority,
  rs.avg_resolution_minutes AS avg_resolution_minutes,
  {{divide_decimal(100.0 * COALESCE(bc.breach_count, 0), NULLIF(tc.ticket_count, 0))}} AS resolution_breach_rate
FROM target_tenants tt
JOIN ticket_counts tc ON tc.tenant_id = tt.tenant_id
LEFT JOIN agent_counts ac ON ac.tenant_id = tt.tenant_id
LEFT JOIN message_counts mc ON mc.tenant_id = tt.tenant_id
LEFT JOIN priority_counts pc ON pc.tenant_id = tt.tenant_id
LEFT JOIN resolution_stats rs ON rs.tenant_id = tt.tenant_id
LEFT JOIN breach_counts bc ON bc.tenant_id = tt.tenant_id
ORDER BY resolution_breach_rate DESC NULLS FIRST, tt.tenant_name NULLS LAST, tt.tenant_id NULLS LAST
