SELECT
  t.definition AS definition,
  t.user_count AS user_count,
  {{divide_decimal(t.user_count * 100.0, tot.total_count)}} as pct_of_all_customers
FROM (
  SELECT 'All customers (ever created)' as definition,
    (SELECT count(distinct u1.id) FROM users u1
       WHERE u1.is_staff = false AND u1.created_at < timestamp '2026-01-01') as user_count
  UNION ALL
  SELECT 'Status = active',
    (SELECT count(distinct u2.id) FROM users u2
       WHERE u2.is_staff = false AND u2.status = 'active')
  UNION ALL
  SELECT 'Placed at least one order, ever',
    (SELECT count(distinct u3.id) FROM users u3
       WHERE u3.is_staff = false
         AND EXISTS (SELECT 1 FROM orders o3 WHERE o3.user_id = u3.id
                       AND o3.placed_at < timestamp '2026-01-01'))
  UNION ALL
  SELECT 'Placed at least one order in trailing 12 months',
    (SELECT count(distinct u4.id) FROM users u4
       WHERE u4.is_staff = false
         AND EXISTS (SELECT 1 FROM orders o4 WHERE o4.user_id = u4.id
                       AND o4.placed_at >= timestamp '2025-01-01'
                       AND o4.placed_at < timestamp '2026-01-01'))
  UNION ALL
  SELECT 'Has an active or trialing subscription',
    (SELECT count(distinct u5.id) FROM users u5
       WHERE u5.is_staff = false
         AND EXISTS (SELECT 1 FROM subscriptions s5 WHERE s5.user_id = u5.id
                       AND s5.status IN ('active','trialing')))
  UNION ALL
  SELECT 'Logged in within last 90 days of data',
    (SELECT count(distinct u6.id) FROM users u6
       WHERE u6.is_staff = false
         AND u6.last_login_at >= timestamp '2025-10-03'
         AND u6.last_login_at < timestamp '2026-01-01')
) t
CROSS JOIN (
  SELECT count(distinct u0.id) as total_count
  FROM users u0
  WHERE u0.is_staff = false AND u0.created_at < timestamp '2026-01-01'
) tot
ORDER BY t.user_count DESC NULLS FIRST, t.definition NULLS LAST
