SELECT t.id AS tenant_id,
       t.name AS tenant_name,
       t.status AS tenant_status,
       COUNT(CASE WHEN u.is_staff THEN u.id END) AS staff_user_count,
       COUNT(CASE WHEN u.is_staff AND um.has_mfa THEN u.id END) AS staff_users_with_mfa,
       {{divide_decimal(100.0 * COUNT(CASE WHEN u.is_staff AND um.has_mfa THEN u.id END), NULLIF(COUNT(CASE WHEN u.is_staff THEN u.id END), 0))}} AS staff_mfa_rate_pct,
       COUNT(CASE WHEN NOT u.is_staff THEN u.id END) AS shopper_user_count,
       COUNT(CASE WHEN NOT u.is_staff AND um.has_mfa THEN u.id END) AS shopper_users_with_mfa,
       {{divide_decimal(100.0 * COUNT(CASE WHEN NOT u.is_staff AND um.has_mfa THEN u.id END), NULLIF(COUNT(CASE WHEN NOT u.is_staff THEN u.id END), 0))}} AS shopper_mfa_rate_pct,
       COUNT(u.id) AS total_users
FROM tenants t
JOIN users u
  ON u.tenant_id = t.id
 AND u.deleted_at IS NULL
LEFT JOIN (
    SELECT tenant_id, user_id, true AS has_mfa
    FROM mfa_devices
    WHERE confirmed_at IS NOT NULL
    GROUP BY tenant_id, user_id
) um
  ON um.tenant_id = u.tenant_id
 AND um.user_id = u.id
GROUP BY t.id, t.name, t.status
ORDER BY staff_mfa_rate_pct ASC NULLS LAST, tenant_name ASC NULLS LAST, t.id ASC NULLS LAST
{{fetch_first(50)}}
