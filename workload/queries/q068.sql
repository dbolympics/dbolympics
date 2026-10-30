WITH months AS (
  SELECT DISTINCT month_label, month_start
  FROM calendar_days
  WHERE month_start >= DATE '2023-01-01' AND month_start <= DATE '2025-12-01'
),
live AS (
  SELECT CAST({{date_trunc('month', occurred_at)}} AS date) AS month_start,
         count(*) AS live_events,
         count(*) FILTER (WHERE actor_user_id IS NULL) AS live_null_actor,
         count(*) FILTER (WHERE actor_type IN ('system','api_key','service_account')) AS live_system_api
  FROM audit_log
  GROUP BY 1
),
archive AS (
  SELECT CAST({{date_trunc('month', occurred_at)}} AS date) AS month_start,
         count(*) AS archived_events,
         count(*) FILTER (WHERE actor_user_id IS NULL) AS archived_null_actor,
         count(*) FILTER (WHERE actor_type IN ('system','api_key','service_account')) AS archived_system_api
  FROM audit_log_archive
  GROUP BY 1
),
actor_types AS (
  SELECT month_start, actor_type
  FROM (
    SELECT CAST({{date_trunc('month', occurred_at)}} AS date) AS month_start, actor_type FROM audit_log
    UNION ALL
    SELECT CAST({{date_trunc('month', occurred_at)}} AS date) AS month_start, actor_type FROM audit_log_archive
  ) t
  GROUP BY month_start, actor_type
),
distinct_actor_types AS (
  SELECT month_start, count(*) AS distinct_actor_type_values
  FROM actor_types
  GROUP BY month_start
),
access AS (
  SELECT CAST({{date_trunc('month', occurred_at)}} AS date) AS month_start, count(*) AS access_events
  FROM access_log
  GROUP BY 1
)
SELECT
  m.month_label AS month,
  coalesce(l.live_events,0) AS audit_log_live_events,
  coalesce(a.archived_events,0) AS audit_log_archived_events,
  coalesce(l.live_events,0) + coalesce(a.archived_events,0) AS total_audit_events,
  CASE WHEN (coalesce(l.live_events,0)+coalesce(a.archived_events,0)) = 0 THEN NULL
  ELSE CAST((coalesce(l.live_null_actor,0)+coalesce(a.archived_null_actor,0)) AS numeric(18,6)) / (coalesce(l.live_events,0)+coalesce(a.archived_events,0))
  END AS pct_actor_user_id_null,
  coalesce(dat.distinct_actor_type_values,0) AS distinct_actor_type_values,
  CASE WHEN (coalesce(l.live_events,0)+coalesce(a.archived_events,0)) = 0 THEN NULL
  ELSE CAST((coalesce(l.live_system_api,0)+coalesce(a.archived_system_api,0)) AS numeric(18,6)) / (coalesce(l.live_events,0)+coalesce(a.archived_events,0))
  END AS pct_actor_type_system_or_api,
  coalesce(acc.access_events,0) AS access_log_events
FROM months m
LEFT JOIN live l ON l.month_start = m.month_start
LEFT JOIN archive a ON a.month_start = m.month_start
LEFT JOIN distinct_actor_types dat ON dat.month_start = m.month_start
LEFT JOIN access acc ON acc.month_start = m.month_start
ORDER BY m.month_start NULLS LAST, m.month_label NULLS LAST
