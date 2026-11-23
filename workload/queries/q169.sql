SELECT
  t0.industry AS industry,
  t0.tenant_count AS tenant_count,
  COALESCE(t1.tenants_with_any_loyalty_program, 0) AS tenants_with_any_loyalty_program,
  COALESCE(t2.active_customers, 0) AS active_customers,
  COALESCE(t3.loyalty_members, 0) AS loyalty_members,
  CASE WHEN COALESCE(t2.active_customers, 0) = 0 THEN 0
       ELSE {{divide_decimal(100.0 * COALESCE(t3.loyalty_members, 0), t2.active_customers)}}
  END AS pct_customers_enrolled,
  COALESCE(t4.referred_customers, 0) AS referred_customers,
  CASE WHEN COALESCE(t2.active_customers, 0) = 0 THEN 0
       ELSE {{divide_decimal(100.0 * COALESCE(t4.referred_customers, 0), t2.active_customers)}}
  END AS pct_customers_referred
FROM (
  SELECT COALESCE(t.industry, 'Unknown') AS industry, COUNT(DISTINCT t.id) AS tenant_count
  FROM tenants t
  GROUP BY COALESCE(t.industry, 'Unknown')
) t0
LEFT JOIN (
  SELECT COALESCE(t.industry, 'Unknown') AS industry, COUNT(DISTINCT t.id) AS tenants_with_any_loyalty_program
  FROM tenants t
  JOIN loyalty_programs lp ON lp.tenant_id = t.id
  GROUP BY COALESCE(t.industry, 'Unknown')
) t1 ON t1.industry = t0.industry
LEFT JOIN (
  SELECT COALESCE(t.industry, 'Unknown') AS industry, COUNT(DISTINCT u.id) AS active_customers
  FROM tenants t
  JOIN users u ON u.tenant_id = t.id AND u.is_staff = false
  JOIN orders o ON o.user_id = u.id AND o.tenant_id = t.id
  WHERE o.placed_at >= TIMESTAMP '2023-01-01' AND o.placed_at < TIMESTAMP '2026-01-01'
  GROUP BY COALESCE(t.industry, 'Unknown')
) t2 ON t2.industry = t0.industry
LEFT JOIN (
  SELECT COALESCE(t.industry, 'Unknown') AS industry, COUNT(DISTINCT u.id) AS loyalty_members
  FROM tenants t
  JOIN users u ON u.tenant_id = t.id AND u.is_staff = false
  JOIN orders o ON o.user_id = u.id AND o.tenant_id = t.id
  JOIN loyalty_accounts la ON la.user_id = u.id AND la.tenant_id = t.id
  WHERE o.placed_at >= TIMESTAMP '2023-01-01' AND o.placed_at < TIMESTAMP '2026-01-01'
  GROUP BY COALESCE(t.industry, 'Unknown')
) t3 ON t3.industry = t0.industry
LEFT JOIN (
  SELECT COALESCE(t.industry, 'Unknown') AS industry, COUNT(DISTINCT u.id) AS referred_customers
  FROM tenants t
  JOIN users u ON u.tenant_id = t.id AND u.is_staff = false
  JOIN orders o ON o.user_id = u.id AND o.tenant_id = t.id
  JOIN referral_redemptions rr ON rr.referred_user_id = u.id AND rr.tenant_id = t.id
  WHERE o.placed_at >= TIMESTAMP '2023-01-01' AND o.placed_at < TIMESTAMP '2026-01-01'
  GROUP BY COALESCE(t.industry, 'Unknown')
) t4 ON t4.industry = t0.industry
ORDER BY COALESCE(t2.active_customers, 0) DESC NULLS FIRST, t0.industry ASC NULLS LAST
