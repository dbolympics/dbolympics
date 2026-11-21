WITH tickets_2025 AS (
  SELECT id, tenant_id, created_at, first_response_at, resolved_at
  FROM tickets
  WHERE created_at >= DATE '2025-01-01' AND created_at < DATE '2026-01-01'
),
tagged AS (
  SELECT
    ttm.ticket_id AS ticket_id,
    st.name AS tag_name,
    t.created_at AS created_at,
    t.first_response_at AS first_response_at,
    t.resolved_at AS resolved_at
  FROM ticket_tags_map ttm
  JOIN support_tags st
    ON st.id = ttm.support_tag_id AND st.tenant_id = ttm.tenant_id
  JOIN tickets_2025 t
    ON t.id = ttm.ticket_id
),
breaches_per_ticket AS (
  SELECT
    ticket_id,
    {{bool_or(breach_kind = 'first_response')}} AS fr_breach,
    {{bool_or(breach_kind = 'resolution')}} AS res_breach
  FROM sla_breaches
  WHERE breach_kind IN ('first_response', 'resolution')
  GROUP BY ticket_id
),
tag_stats AS (
  SELECT
    tagged.tag_name AS tag_name,
    COUNT(DISTINCT tagged.ticket_id) AS ticket_count,
    AVG({{divide_decimal({{seconds_between(tagged.created_at, tagged.first_response_at)}}, 60.0)}})
      FILTER (WHERE tagged.first_response_at IS NOT NULL) AS avg_first_response_minutes,
    AVG({{divide_decimal({{seconds_between(tagged.created_at, tagged.resolved_at)}}, 60.0)}})
      FILTER (WHERE tagged.resolved_at IS NOT NULL) AS avg_resolution_minutes,
    COUNT(DISTINCT tagged.ticket_id) FILTER (WHERE bpt.fr_breach) AS fr_breach_count,
    COUNT(DISTINCT tagged.ticket_id) FILTER (WHERE bpt.res_breach) AS res_breach_count
  FROM tagged
  LEFT JOIN breaches_per_ticket bpt ON bpt.ticket_id = tagged.ticket_id
  GROUP BY tagged.tag_name
),
totals AS (
  SELECT
    (SELECT COUNT(*) FROM tickets_2025) AS total_tickets_2025,
    (SELECT COUNT(DISTINCT ttm.ticket_id)
       FROM ticket_tags_map ttm
       JOIN tickets_2025 t ON t.id = ttm.ticket_id) AS total_tagged_tickets_2025
)
SELECT
  tag_stats.tag_name AS tag_name,
  tag_stats.ticket_count AS ticket_count,
  tag_stats.avg_first_response_minutes AS avg_first_response_minutes,
  tag_stats.avg_resolution_minutes AS avg_resolution_minutes,
  {{divide_decimal(CAST(tag_stats.fr_breach_count AS numeric(18,6)), NULLIF(tag_stats.ticket_count, 0))}} AS first_response_breach_rate,
  {{divide_decimal(CAST(tag_stats.res_breach_count AS numeric(18,6)), NULLIF(tag_stats.ticket_count, 0))}} AS resolution_breach_rate,
  totals.total_tagged_tickets_2025 AS total_tagged_tickets_2025,
  totals.total_tickets_2025 AS total_tickets_2025
FROM tag_stats
CROSS JOIN totals
ORDER BY tag_stats.ticket_count DESC NULLS FIRST, tag_stats.tag_name ASC NULLS LAST
{{fetch_first(20)}}
