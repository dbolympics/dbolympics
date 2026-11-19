WITH combined_log AS (
  SELECT tenant_id, action, actor_user_id, entity_table, occurred_at
  FROM audit_log
  UNION ALL
  SELECT tenant_id, action, actor_user_id, entity_table, occurred_at
  FROM audit_log_archive
),
role_changes AS (
  SELECT
    occurred_at,
    action,
    actor_user_id
  FROM combined_log
  WHERE entity_table = 'user_roles'
    AND action IN ('create', 'delete')
    AND occurred_at >= DATE '2023-01-01'
    AND occurred_at < DATE '2026-01-01'
),
months AS (
  SELECT DISTINCT month_label, month_start
  FROM calendar_days
  WHERE month_start >= DATE '2023-01-01' AND month_start < DATE '2026-01-01'
),
monthly_changes AS (
  SELECT
    {{year_month(occurred_at)}} AS month_label,
    count(*) FILTER (WHERE action = 'create') AS role_grants_created,
    count(*) FILTER (WHERE action = 'delete') AS role_grants_removed,
    count(DISTINCT actor_user_id) AS distinct_actor_user_id,
    count(*) AS total_changes,
    count(*) FILTER (WHERE actor_user_id IS NULL) AS null_actor_changes
  FROM role_changes
  GROUP BY 1
)
SELECT
  months.month_label AS month,
  coalesce(monthly_changes.role_grants_created, 0) AS role_grants_created,
  coalesce(monthly_changes.role_grants_removed, 0) AS role_grants_removed,
  coalesce(monthly_changes.role_grants_created, 0) - coalesce(monthly_changes.role_grants_removed, 0) AS net_change,
  coalesce(monthly_changes.distinct_actor_user_id, 0) AS distinct_actor_user_id,
  CASE WHEN coalesce(monthly_changes.total_changes,0) = 0 THEN NULL
       ELSE {{divide_decimal(100.0 * monthly_changes.null_actor_changes, monthly_changes.total_changes)}}
  END AS pct_actor_user_id_null
FROM months
LEFT JOIN monthly_changes ON months.month_label = monthly_changes.month_label
ORDER BY months.month_label NULLS LAST
