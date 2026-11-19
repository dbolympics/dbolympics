WITH months AS (
  SELECT month_label, MAX(calendar_date) AS month_end
  FROM calendar_days
  WHERE year_num = 2025
  GROUP BY month_label
),
eligible_users AS (
  SELECT m.month_label AS month_label, m.month_end AS month_end, u.id AS user_id, u.is_staff AS is_staff
  FROM months m
  JOIN users u
    ON u.created_at <= m.month_end
   AND (u.deleted_at IS NULL OR u.deleted_at > m.month_end)
),
user_mfa AS (
  SELECT eu.month_label AS month_label, eu.month_end AS month_end, eu.user_id AS user_id, eu.is_staff AS is_staff,
    EXISTS (
      SELECT 1 FROM mfa_devices md
      WHERE md.user_id = eu.user_id AND md.confirmed_at <= eu.month_end
    ) AS has_mfa
  FROM eligible_users eu
),
monthly_summary AS (
  SELECT month_label,
    COUNT(*) FILTER (WHERE is_staff) AS staff_users,
    COUNT(*) FILTER (WHERE is_staff AND has_mfa) AS staff_mfa_users,
    COUNT(*) FILTER (WHERE NOT is_staff) AS shopper_users,
    COUNT(*) FILTER (WHERE NOT is_staff AND has_mfa) AS shopper_mfa_users
  FROM user_mfa
  GROUP BY month_label
)
SELECT
  month_label,
  staff_users,
  staff_mfa_users AS staff_users_with_mfa,
  {{divide_decimal(100.0 * staff_mfa_users, NULLIF(staff_users,0))}} AS staff_mfa_rate_pct,
  shopper_users,
  shopper_mfa_users AS shopper_users_with_mfa,
  {{divide_decimal(100.0 * shopper_mfa_users, NULLIF(shopper_users,0))}} AS shopper_mfa_rate_pct
FROM monthly_summary
ORDER BY month_label NULLS LAST
