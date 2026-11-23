WITH tenant_filter AS (
  SELECT id, name FROM tenants WHERE name IN ('Marrowby & Vane','Studio Vrij','Cragsley Outfitters')
),
ticket_tags AS (
  SELECT t.id AS ticket_id, t.tenant_id AS tenant_id, t.created_at AS created_at, t.resolved_at AS resolved_at, st.name AS tag_name
  FROM tickets t
  JOIN ticket_tags_map ttm ON ttm.ticket_id = t.id
  JOIN support_tags st ON st.id = ttm.support_tag_id
  JOIN tenant_filter tf ON tf.id = t.tenant_id
  WHERE t.created_at >= DATE '2025-01-01' AND t.created_at < DATE '2026-01-01'
),
tenant_totals AS (
  SELECT t.tenant_id AS tenant_id, COUNT(*) AS total_tickets
  FROM tickets t
  JOIN tenant_filter tf ON tf.id = t.tenant_id
  WHERE t.created_at >= DATE '2025-01-01' AND t.created_at < DATE '2026-01-01'
  GROUP BY t.tenant_id
),
breaches AS (
  SELECT DISTINCT ticket_id FROM sla_breaches WHERE breach_kind = 'resolution'
)
SELECT
  tf.name AS tenant_name,
  tt.tag_name AS tag_name,
  COUNT(*) AS ticket_count,
  {{divide_decimal(100.0 * COUNT(*), tot.total_tickets)}} AS pct_of_tenant_tickets,
  AVG(CASE WHEN tt.resolved_at IS NOT NULL THEN {{divide_decimal({{seconds_between(tt.created_at, tt.resolved_at)}}, 60.0)}} END) AS avg_resolution_minutes,
  {{divide_decimal(100.0 * COUNT(DISTINCT CASE WHEN b.ticket_id IS NOT NULL THEN tt.ticket_id END), COUNT(*))}} AS resolution_breach_rate
FROM ticket_tags tt
JOIN tenant_filter tf ON tf.id = tt.tenant_id
JOIN tenant_totals tot ON tot.tenant_id = tt.tenant_id
LEFT JOIN breaches b ON b.ticket_id = tt.ticket_id
GROUP BY tf.name, tt.tag_name, tot.total_tickets
ORDER BY tf.name NULLS LAST, ticket_count DESC NULLS FIRST, tt.tag_name NULLS LAST, tot.total_tickets NULLS LAST
