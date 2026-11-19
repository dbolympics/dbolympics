SELECT
  tn.name AS merchant_name,
  q123.tickets_q123 AS tickets_q123,
  q123.avg_agents_q123 AS avg_agents_q1_q3,
  ({{divide_decimal(q123.tickets_q123, 3.0)}}) / NULLIF(q123.avg_agents_q123, 0) AS tickets_per_agent_q1_q3,
  q4.tickets_q4 AS tickets_q4,
  q4.agents_q4 AS agents_q4,
  {{divide_decimal(CAST(q4.tickets_q4 AS numeric(18,6)), NULLIF(q4.agents_q4, 0))}} AS tickets_per_agent_q4
FROM tenants tn
JOIN (
  SELECT qt.tenant_id AS tenant_id,
         SUM(COALESCE(qd.tickets, 0)) AS tickets_q123,
         AVG(CAST(COALESCE(qd.agents, 0) AS NUMERIC(18,6))) AS avg_agents_q123
  FROM (
    SELECT tenant_id
    FROM tickets
    WHERE created_at >= TIMESTAMP '2025-01-01' AND created_at < TIMESTAMP '2026-01-01'
    GROUP BY tenant_id
    HAVING COUNT(*) >= 20
  ) qt
  CROSS JOIN (SELECT 1 AS q UNION ALL SELECT 2 UNION ALL SELECT 3) quarters
  LEFT JOIN (
    SELECT tenant_id,
           EXTRACT(QUARTER FROM created_at) AS q,
           COUNT(*) AS tickets,
           COUNT(DISTINCT assignee_agent_id) AS agents
    FROM tickets
    WHERE created_at >= TIMESTAMP '2025-01-01' AND created_at < TIMESTAMP '2025-10-01'
    GROUP BY tenant_id, EXTRACT(QUARTER FROM created_at)
  ) qd ON qd.tenant_id = qt.tenant_id AND qd.q = quarters.q
  GROUP BY qt.tenant_id
) q123 ON q123.tenant_id = tn.id
JOIN (
  SELECT tenant_id,
         COUNT(*) AS tickets_q4,
         COUNT(DISTINCT assignee_agent_id) AS agents_q4
  FROM tickets
  WHERE created_at >= TIMESTAMP '2025-10-01' AND created_at < TIMESTAMP '2026-01-01'
  GROUP BY tenant_id
) q4 ON q4.tenant_id = tn.id
ORDER BY tickets_per_agent_q4 DESC NULLS FIRST, merchant_name ASC NULLS LAST, tn.id NULLS LAST
