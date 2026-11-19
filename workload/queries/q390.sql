SELECT
  COALESCE(u.full_name, 'Unknown/unassigned') AS staff_name,
  COUNT(*) AS total_adjustments_logged,
  COUNT(*) FILTER (WHERE sa.reason = 'Missing - suspected theft') AS theft_tagged_count,
  {{divide_decimal(100.0 * COUNT(*) FILTER (WHERE sa.reason = 'Missing - suspected theft'), COUNT(*))}} AS pct_theft_of_own_adjustments,
  COUNT(*) FILTER (WHERE sa.reason = 'Damaged in warehouse') AS damage_tagged_count,
  COUNT(*) FILTER (WHERE sa.reason = 'Expired') AS expired_tagged_count,
  COUNT(*) FILTER (WHERE sa.reason = 'Cycle count variance') AS cycle_count_variance_count,
  AVG(EXTRACT(HOUR FROM sa.created_at)) FILTER (WHERE sa.reason = 'Missing - suspected theft') AS avg_hour_of_day_for_theft_entries,
  COUNT(*) OVER () AS total_staff_with_adjustments_2025
FROM stock_adjustments sa
LEFT JOIN users u ON u.id = sa.adjusted_by_user_id
WHERE sa.created_at >= DATE '2025-01-01' AND sa.created_at < DATE '2026-01-01'
GROUP BY sa.adjusted_by_user_id, u.full_name
ORDER BY theft_tagged_count DESC NULLS FIRST, total_adjustments_logged DESC NULLS FIRST, staff_name ASC NULLS LAST, sa.adjusted_by_user_id ASC NULLS LAST
{{fetch_first(50)}}
