SELECT
  t.name AS tenant_name,
  t.status AS tenant_status,
  COUNT(*) AS total_login_attempts,
  SUM(CASE WHEN la.succeeded THEN 1 ELSE 0 END) AS successful_logins,
  SUM(CASE WHEN NOT la.succeeded THEN 1 ELSE 0 END) AS failed_logins,
  {{divide_decimal(100.0 * SUM(CASE WHEN NOT la.succeeded THEN 1 ELSE 0 END), COUNT(*))}} AS failure_rate_pct,
  COUNT(DISTINCT la.email) AS distinct_emails_attempted,
  COUNT(DISTINCT la.ip_address) AS distinct_ip_addresses,
  (SELECT MAX(ip_count) FROM (
      SELECT COUNT(*) AS ip_count
      FROM login_attempts la2
      WHERE la2.tenant_id = la.tenant_id
        AND la2.occurred_at >= TIMESTAMP '2025-11-24 00:00:00'
        AND la2.occurred_at <= TIMESTAMP '2025-11-30 23:59:59'
      GROUP BY la2.ip_address
  ) ip_counts) AS max_attempts_single_ip,
  {{divide_decimal(100.0 * COUNT(*), (
SELECT COUNT(*)
FROM login_attempts la3
WHERE la3.occurred_at >= TIMESTAMP '2025-11-24 00:00:00'
  AND la3.occurred_at <= TIMESTAMP '2025-11-30 23:59:59'
))}} AS pct_of_platform_total
FROM login_attempts la
JOIN tenants t ON t.id = la.tenant_id
WHERE la.occurred_at >= TIMESTAMP '2025-11-24 00:00:00'
  AND la.occurred_at <= TIMESTAMP '2025-11-30 23:59:59'
GROUP BY t.id, t.name, t.status, la.tenant_id
ORDER BY total_login_attempts DESC NULLS FIRST, tenant_name ASC NULLS LAST, t.id ASC NULLS LAST
