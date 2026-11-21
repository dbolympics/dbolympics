SELECT
  t.name AS merchant_name,
  tk.ticket_count AS tickets_2025,
  {{divide_decimal(CAST(coalesce(msg.total_messages, 0) AS numeric(18,6)), tk.ticket_count)}} AS avg_messages_per_ticket,
  {{divide_decimal(CAST(coalesce(msg.total_public, 0) AS numeric(18,6)), tk.ticket_count)}} AS avg_public_messages_per_ticket,
  {{divide_decimal(CAST(coalesce(tags.total_tags, 0) AS numeric(18,6)), tk.ticket_count)}} AS avg_distinct_tags_per_ticket,
  count(*) OVER () AS qualifying_tenant_count
FROM tenants t
JOIN (
  SELECT tenant_id, count(*) AS ticket_count
  FROM tickets
  WHERE created_at >= timestamp '2025-01-01' AND created_at < timestamp '2026-01-01'
  GROUP BY tenant_id
) tk ON tk.tenant_id = t.id
LEFT JOIN (
  SELECT ti.tenant_id AS tenant_id,
    count(*) AS total_messages,
    count(*) FILTER (WHERE tm.is_public) AS total_public
  FROM ticket_messages tm
  JOIN tickets ti ON ti.id = tm.ticket_id AND ti.tenant_id = tm.tenant_id
  WHERE ti.created_at >= timestamp '2025-01-01' AND ti.created_at < timestamp '2026-01-01'
  GROUP BY ti.tenant_id
) msg ON msg.tenant_id = t.id
LEFT JOIN (
  SELECT ti.tenant_id AS tenant_id,
    count(*) AS total_tags
  FROM ticket_tags_map ttm
  JOIN tickets ti ON ti.id = ttm.ticket_id AND ti.tenant_id = ttm.tenant_id
  WHERE ti.created_at >= timestamp '2025-01-01' AND ti.created_at < timestamp '2026-01-01'
  GROUP BY ti.tenant_id
) tags ON tags.tenant_id = t.id
WHERE tk.ticket_count >= 20
ORDER BY avg_messages_per_ticket DESC NULLS FIRST, merchant_name ASC NULLS LAST, t.id ASC NULLS LAST
{{fetch_first(50)}}
