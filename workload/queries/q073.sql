WITH user_mfa AS (
  SELECT user_id, tenant_id,
         max(case when confirmed_at is not null then 1 else 0 end) as has_confirmed,
         1 as has_any
  FROM mfa_devices
  GROUP BY user_id, tenant_id
)
SELECT
  u.is_staff AS is_staff,
  u.status AS status,
  count(*) as total_users,
  sum(case when um.has_confirmed = 1 then 1 else 0 end) as users_with_confirmed_mfa,
  {{divide_decimal(100.0 * sum(case when um.has_confirmed = 1 then 1 else 0 end), count(*))}} as pct_with_confirmed_mfa,
  sum(case when um.has_any = 1 then 1 else 0 end) as users_with_any_mfa_device,
  {{divide_decimal(100.0 * sum(case when um.has_any = 1 then 1 else 0 end), count(*))}} as pct_with_any_mfa_device
FROM users u
LEFT JOIN user_mfa um ON um.user_id = u.id AND um.tenant_id = u.tenant_id
WHERE u.deleted_at is null
GROUP BY u.is_staff, u.status
ORDER BY u.is_staff desc NULLS FIRST, u.status NULLS LAST
