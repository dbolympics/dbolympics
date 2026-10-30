WITH tagged_tickets AS (
  SELECT DISTINCT t.id AS ticket_id, t.tenant_id AS tenant_id, t.created_at AS created_at, t.resolved_at AS resolved_at
  FROM tickets t
  JOIN ticket_tags_map ttm ON ttm.ticket_id = t.id AND ttm.tenant_id = t.tenant_id
  JOIN support_tags st ON st.id = ttm.support_tag_id AND st.tenant_id = t.tenant_id
  JOIN tenants te ON te.id = t.tenant_id
  WHERE te.name IN ('Marrowby & Vane','Studio Vrij','Cragsley Outfitters')
    AND st.name IN ('delivery','where-is-my-order')
    AND t.created_at >= DATE '2025-01-01' AND t.created_at < DATE '2026-01-01'
),
breaches AS (
  SELECT DISTINCT ticket_id FROM sla_breaches WHERE breach_kind = 'resolution'
)
SELECT
  te.name AS tenant_name,
  {{year_month({{date_trunc('month', tt.created_at)}})}} AS month_label,
  COUNT(*) AS ticket_count,
  AVG({{seconds_between(tt.created_at, tt.resolved_at)}}/60) FILTER (WHERE tt.resolved_at IS NOT NULL) AS avg_resolution_minutes,
  100.0 * COUNT(*) FILTER (WHERE b.ticket_id IS NOT NULL) / COUNT(*) AS resolution_breach_rate
FROM tagged_tickets tt
JOIN tenants te ON te.id = tt.tenant_id
LEFT JOIN breaches b ON b.ticket_id = tt.ticket_id
GROUP BY te.name, {{date_trunc('month', tt.created_at)}}
ORDER BY te.name NULLS LAST, month_label NULLS LAST
