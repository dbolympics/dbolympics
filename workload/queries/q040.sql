SELECT
  {{year_month({{date_trunc('month', x.created_at)}})}} AS month,
  count(*) AS tickets_total,
  count(*) FILTER (WHERE x.is_delivery) AS tickets_delivery_related,
  100.0 * count(*) FILTER (WHERE x.is_delivery) / count(*) AS delivery_share_pct,
  avg({{seconds_between(x.created_at, x.first_response_at)}}/3600) FILTER (WHERE x.is_delivery AND x.first_response_at IS NOT NULL) AS avg_first_response_hours_delivery,
  avg({{seconds_between(x.created_at, x.first_response_at)}}/3600) FILTER (WHERE NOT x.is_delivery AND x.first_response_at IS NOT NULL) AS avg_first_response_hours_other,
  avg({{seconds_between(x.created_at, x.resolved_at)}}/3600) FILTER (WHERE x.is_delivery AND x.resolved_at IS NOT NULL) AS avg_resolution_hours_delivery,
  avg({{seconds_between(x.created_at, x.resolved_at)}}/3600) FILTER (WHERE NOT x.is_delivery AND x.resolved_at IS NOT NULL) AS avg_resolution_hours_other
FROM (
  SELECT
    t.id AS id,
    t.tenant_id AS tenant_id,
    t.created_at AS created_at,
    t.first_response_at AS first_response_at,
    t.resolved_at AS resolved_at,
    EXISTS (
      SELECT 1
      FROM ticket_tags_map ttm
      JOIN support_tags st ON st.id = ttm.support_tag_id AND st.tenant_id = ttm.tenant_id
      WHERE ttm.ticket_id = t.id
        AND ttm.tenant_id = t.tenant_id
        AND lower(st.name) IN ('delivery', 'where-is-my-order')
    ) AS is_delivery
  FROM tickets t
  WHERE t.created_at >= timestamp '2024-07-01'
    AND t.created_at < timestamp '2026-01-01'
) x
GROUP BY {{date_trunc('month', x.created_at)}}
ORDER BY {{date_trunc('month', x.created_at)}} NULLS LAST
