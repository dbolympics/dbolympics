WITH staff AS (
  SELECT id, status, last_login_at
  FROM users
  WHERE is_staff = true AND deleted_at IS NULL
),
joined AS (
  SELECT
    s.id AS user_id,
    s.status AS status,
    s.last_login_at AS last_login_at,
    ur.id AS user_role_id,
    ur.created_at AS role_granted_at,
    r.is_system AS is_system
  FROM staff s
  LEFT JOIN user_roles ur ON ur.user_id = s.id
  LEFT JOIN roles r ON r.id = ur.role_id
)
SELECT
  status,
  COUNT(DISTINCT user_id) AS staff_user_count,
  COUNT(DISTINCT user_id) FILTER (WHERE user_role_id IS NOT NULL) AS users_with_any_role,
  {{divide_decimal(CAST(COUNT(DISTINCT user_id) FILTER (WHERE user_role_id IS NOT NULL) AS numeric(18,6)), NULLIF(COUNT(DISTINCT user_id),0))}} AS pct_with_any_role,
  COUNT(DISTINCT user_id) FILTER (WHERE is_system = true) AS users_with_system_role,
  {{divide_decimal(CAST(COUNT(user_role_id) AS numeric(18,6)), NULLIF(COUNT(DISTINCT user_id),0))}} AS avg_roles_per_user,
  {{percentile_cont_filter(0.5, (DATE '2025-12-31' - CAST(role_granted_at AS date)), user_role_id IS NOT NULL)}} AS median_days_since_role_granted,
  {{divide_decimal(CAST(COUNT(DISTINCT user_id) FILTER (WHERE last_login_at IS NULL) AS numeric(18,6)), NULLIF(COUNT(DISTINCT user_id),0))}} AS pct_never_logged_in,
  {{percentile_cont_filter(0.5, (DATE '2025-12-31' - CAST(last_login_at AS date)), last_login_at IS NOT NULL)}} AS median_days_since_last_login
FROM joined
GROUP BY status
ORDER BY CASE status WHEN 'active' THEN 1 WHEN 'invited' THEN 2 WHEN 'suspended' THEN 3 WHEN 'deactivated' THEN 4 ELSE 5 END NULLS LAST, status NULLS LAST
