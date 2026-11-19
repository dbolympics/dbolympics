WITH role_instance AS (
  SELECT r.id AS role_id, r.tenant_id AS tenant_id, r.name AS name, r.is_system AS is_system,
         COUNT(DISTINCT rp.permission_id) AS perm_count
  FROM roles r
  JOIN role_permissions rp ON rp.role_id = r.id
  GROUP BY r.id, r.tenant_id, r.name, r.is_system
),
assigned AS (
  SELECT ur.role_id AS role_id,
         COUNT(DISTINCT u.id) AS assigned_users,
         COUNT(DISTINCT u.id) FILTER (WHERE u.status = 'active' AND (u.last_login_at IS NULL OR u.last_login_at < DATE '2025-10-05')) AS dormant_users
  FROM user_roles ur
  JOIN users u ON u.id = ur.user_id AND u.tenant_id = ur.tenant_id
  WHERE u.deleted_at IS NULL
  GROUP BY ur.role_id
),
qualifying AS (
  SELECT ri.tenant_id AS tenant_id, ri.name AS name, ri.is_system AS is_system, ri.perm_count AS perm_count,
         a.assigned_users AS assigned_users, a.dormant_users AS dormant_users
  FROM role_instance ri
  JOIN assigned a ON a.role_id = ri.role_id
  WHERE ri.perm_count >= 1 AND a.assigned_users >= 1
)
SELECT
  name AS role_name,
  COUNT(DISTINCT tenant_id) AS tenant_count,
  {{divide_decimal(100.0 * SUM(CASE WHEN is_system THEN 1 ELSE 0 END), COUNT(*))}} AS pct_is_system,
  AVG(CAST(perm_count AS NUMERIC(18,6))) AS avg_permission_count,
  MAX(perm_count) AS max_permission_count,
  SUM(assigned_users) AS total_users_assigned,
  SUM(dormant_users) AS total_users_dormant,
  {{divide_decimal(100.0 * SUM(dormant_users), NULLIF(SUM(assigned_users), 0))}} AS dormant_rate_pct
FROM qualifying
WHERE name <> 'Owner'
GROUP BY name
ORDER BY total_users_assigned DESC NULLS FIRST, role_name NULLS LAST
{{fetch_first(50)}}
