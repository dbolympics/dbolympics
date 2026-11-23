SELECT
  stn.name AS tag_name,
  COALESCE(a.cnt,0) AS tickets_last_6mo,
  COALESCE(b.cnt,0) AS tickets_prior_6mo,
  {{divide_decimal(COALESCE(a.cnt,0) * 100.0, NULLIF(totals.total_a,0))}} AS share_last_6mo_pct,
  {{divide_decimal(COALESCE(b.cnt,0) * 100.0, NULLIF(totals.total_b,0))}} AS share_prior_6mo_pct,
  {{divide_decimal(COALESCE(a.cnt,0) * 100.0, NULLIF(totals.total_a,0))}}
  - {{divide_decimal(COALESCE(b.cnt,0) * 100.0, NULLIF(totals.total_b,0))}} AS share_change_pp,
  a.avg_res_hours AS avg_resolution_hours_last_6mo
FROM (SELECT DISTINCT name FROM support_tags) stn
LEFT JOIN (
  SELECT st.name AS name, COUNT(*) AS cnt,
         AVG({{divide_decimal({{seconds_between(t.created_at, t.resolved_at)}}, 3600.0)}}) AS avg_res_hours
  FROM ticket_tags_map ttm
  JOIN tickets t ON t.id = ttm.ticket_id
  JOIN support_tags st ON st.id = ttm.support_tag_id
  WHERE t.created_at >= DATE '2025-07-01' AND t.created_at < DATE '2026-01-01'
  GROUP BY st.name
) a ON a.name = stn.name
LEFT JOIN (
  SELECT st.name AS name, COUNT(*) AS cnt
  FROM ticket_tags_map ttm
  JOIN tickets t ON t.id = ttm.ticket_id
  JOIN support_tags st ON st.id = ttm.support_tag_id
  WHERE t.created_at >= DATE '2025-01-01' AND t.created_at < DATE '2025-07-01'
  GROUP BY st.name
) b ON b.name = stn.name
CROSS JOIN (
  SELECT
    (SELECT COUNT(*) FROM ticket_tags_map ttm JOIN tickets t ON t.id = ttm.ticket_id
       WHERE t.created_at >= DATE '2025-07-01' AND t.created_at < DATE '2026-01-01') AS total_a,
    (SELECT COUNT(*) FROM ticket_tags_map ttm JOIN tickets t ON t.id = ttm.ticket_id
       WHERE t.created_at >= DATE '2025-01-01' AND t.created_at < DATE '2025-07-01') AS total_b
) totals
WHERE COALESCE(a.cnt,0) > 0 OR COALESCE(b.cnt,0) > 0
ORDER BY tickets_last_6mo DESC NULLS FIRST, tag_name ASC NULLS LAST
{{fetch_first(50)}}
