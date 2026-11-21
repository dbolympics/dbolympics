SELECT
  tn.name AS merchant_name,
  a.mayjun_count AS tickets_created_may_jun_2025,
  {{divide_decimal(a.other_count, 10.0)}} AS avg_monthly_tickets_other_2025,
  CASE WHEN a.other_count = 0 THEN NULL
       ELSE ({{divide_decimal(a.mayjun_count, 2.0)}}) / ({{divide_decimal(a.other_count, 10.0)}})
  END AS spike_ratio,
  CASE WHEN a.mayjun_count = 0 THEN NULL
       ELSE {{divide_decimal(100.0 * COALESCE(d.delivery_count,0), a.mayjun_count)}}
  END AS delivery_tag_share_pct
FROM (
  SELECT tenant_id,
    COUNT(*) FILTER (WHERE created_at >= DATE '2025-01-01' AND created_at < DATE '2026-01-01') AS total_2025,
    COUNT(*) FILTER (WHERE created_at >= DATE '2025-05-01' AND created_at < DATE '2025-07-01') AS mayjun_count,
    COUNT(*) FILTER (WHERE created_at >= DATE '2025-01-01' AND created_at < DATE '2026-01-01'
                      AND NOT (created_at >= DATE '2025-05-01' AND created_at < DATE '2025-07-01')) AS other_count
  FROM tickets
  GROUP BY tenant_id
) a
JOIN tenants tn ON tn.id = a.tenant_id
LEFT JOIN (
  SELECT t.tenant_id AS tenant_id, COUNT(DISTINCT t.id) AS delivery_count
  FROM tickets t
  JOIN ticket_tags_map ttm ON ttm.ticket_id = t.id
  JOIN support_tags st ON st.id = ttm.support_tag_id
  WHERE t.created_at >= DATE '2025-05-01' AND t.created_at < DATE '2025-07-01'
    AND LOWER(st.name) IN ('delivery', 'where-is-my-order')
  GROUP BY t.tenant_id
) d ON d.tenant_id = a.tenant_id
WHERE a.total_2025 >= 5
ORDER BY a.mayjun_count DESC NULLS FIRST, tn.name ASC NULLS LAST, tn.id ASC NULLS LAST
{{fetch_first(50)}}
