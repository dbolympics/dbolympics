SELECT
  t.name AS tenant_name,
  COUNT(*) AS total_attempts_feb,
  SUM(CASE WHEN la.succeeded = false THEN 1 ELSE 0 END) AS failed_attempts_feb,
  {{divide_decimal(100.0 * SUM(CASE WHEN la.succeeded = false THEN 1 ELSE 0 END), NULLIF(COUNT(*), 0))}} AS pct_failed_feb,
  COUNT(DISTINCT CASE WHEN la.succeeded = false THEN la.email END) AS distinct_emails_with_any_failed_attempt,
  COUNT(DISTINCT CASE WHEN la.succeeded = false THEN la.ip_address END) AS distinct_ips_with_any_failed_attempt,
  (SELECT MAX(cnt) FROM (
      SELECT COUNT(*) AS cnt
      FROM login_attempts la2
      WHERE la2.tenant_id = t.id
        AND la2.succeeded = false
        AND la2.occurred_at >= DATE '2025-02-01'
        AND la2.occurred_at < DATE '2025-03-01'
      GROUP BY la2.ip_address
  ) ip_counts) AS max_failed_attempts_single_ip,
  (SELECT MAX(cnt) FROM (
      SELECT COUNT(*) AS cnt
      FROM login_attempts la3
      WHERE la3.tenant_id = t.id
        AND la3.succeeded = false
        AND la3.occurred_at >= DATE '2025-02-01'
        AND la3.occurred_at < DATE '2025-03-01'
      GROUP BY la3.email
  ) email_counts) AS max_failed_attempts_single_email
FROM login_attempts la
JOIN tenants t ON t.id = la.tenant_id
WHERE la.occurred_at >= DATE '2025-02-01'
  AND la.occurred_at < DATE '2025-03-01'
GROUP BY t.id, t.name
ORDER BY failed_attempts_feb DESC NULLS FIRST, tenant_name ASC NULLS LAST, t.id NULLS LAST
