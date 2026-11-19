WITH staff_totals AS (
  SELECT count(*) AS total_staff
  FROM users
  WHERE is_staff = true AND deleted_at IS NULL
),
cat_users AS (
  SELECT DISTINCT p.category AS category, u.id AS user_id, u.status AS status
  FROM permissions p
  JOIN role_permissions rp ON rp.permission_id = p.id
  JOIN user_roles ur ON ur.role_id = rp.role_id
  JOIN users u ON u.id = ur.user_id
  WHERE u.is_staff = true AND u.deleted_at IS NULL
),
cat_perm_counts AS (
  SELECT category, count(DISTINCT code) AS distinct_permission_codes
  FROM permissions
  GROUP BY category
)
SELECT
  cu.category AS category,
  count(*) AS staff_users_with_category,
  {{divide_decimal(100.0 * count(*), st.total_staff)}} AS pct_of_all_staff,
  count(*) FILTER (WHERE cu.status = 'active') AS active_count,
  count(*) FILTER (WHERE cu.status IN ('invited','suspended','deactivated')) AS non_active_count,
  cpc.distinct_permission_codes AS distinct_permission_codes
FROM cat_users cu
CROSS JOIN staff_totals st
JOIN cat_perm_counts cpc ON cpc.category = cu.category
GROUP BY cu.category, st.total_staff, cpc.distinct_permission_codes
ORDER BY staff_users_with_category DESC NULLS FIRST, cu.category NULLS LAST
