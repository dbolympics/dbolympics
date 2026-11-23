SELECT
  bucket AS resolution_time_bucket,
  COUNT(*) AS ticket_count,
  AVG(CAST(score AS NUMERIC(18,6))) AS avg_csat_score,
  {{divide_decimal(100.0 * SUM(CASE WHEN breached THEN 1 ELSE 0 END), COUNT(*))}} AS pct_resolution_sla_breached,
  AVG(resolution_minutes) AS avg_resolution_minutes
FROM (
  SELECT
    t.id AS ticket_id,
    c.score AS score,
    {{divide_decimal({{seconds_between(t.created_at, t.resolved_at)}}, 60.0)}} AS resolution_minutes,
    EXISTS (
      SELECT 1 FROM sla_breaches sb
      WHERE sb.ticket_id = t.id AND sb.breach_kind = 'resolution'
    ) AS breached,
    CASE
      WHEN {{divide_decimal({{seconds_between(t.created_at, t.resolved_at)}}, 3600.0)}} < 4 THEN 'Under 4h'
      WHEN {{divide_decimal({{seconds_between(t.created_at, t.resolved_at)}}, 3600.0)}} < 24 THEN '4-24h'
      WHEN {{divide_decimal({{seconds_between(t.created_at, t.resolved_at)}}, 3600.0)}} < 72 THEN '1-3 days'
      WHEN {{divide_decimal({{seconds_between(t.created_at, t.resolved_at)}}, 3600.0)}} < 168 THEN '3-7 days'
      ELSE 'Over 7 days'
    END AS bucket
  FROM tickets t
  JOIN csat_responses c ON c.ticket_id = t.id
  WHERE t.created_at >= DATE '2025-01-01'
    AND t.created_at < DATE '2026-01-01'
    AND t.resolved_at IS NOT NULL
) x
GROUP BY bucket
ORDER BY
  CASE bucket
    WHEN 'Under 4h' THEN 1
    WHEN '4-24h' THEN 2
    WHEN '1-3 days' THEN 3
    WHEN '3-7 days' THEN 4
    ELSE 5
  END NULLS LAST
