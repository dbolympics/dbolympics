WITH target AS (
  SELECT week_start
  FROM calendar_days
  WHERE calendar_date = DATE '2025-12-31'
),
windowed AS (
  SELECT
    cd.week_start AS week_start,
    la.email AS email,
    la.ip_address AS ip_address,
    la.succeeded AS succeeded
  FROM login_attempts la
  JOIN calendar_days cd ON cd.calendar_date = CAST(la.occurred_at AS date)
  CROSS JOIN target t
  WHERE cd.week_start BETWEEN t.week_start - INTERVAL '175 days' AND t.week_start
),
ip_counts AS (
  SELECT week_start, ip_address, COUNT(*) AS cnt
  FROM windowed
  GROUP BY week_start, ip_address
),
ip_max AS (
  SELECT week_start, MAX(cnt) AS max_ip_attempts
  FROM ip_counts
  GROUP BY week_start
),
weekly AS (
  SELECT
    week_start,
    COUNT(*) AS total_attempts,
    SUM(CASE WHEN succeeded THEN 1 ELSE 0 END) AS successful_logins,
    SUM(CASE WHEN NOT succeeded THEN 1 ELSE 0 END) AS failed_logins,
    COUNT(DISTINCT email) AS distinct_identities,
    COUNT(DISTINCT ip_address) AS distinct_ips
  FROM windowed
  GROUP BY week_start
)
SELECT
  w.week_start AS week_start,
  w.total_attempts AS total_attempts,
  w.successful_logins AS successful_logins,
  w.failed_logins AS failed_logins,
  {{divide_decimal(100.0 * w.failed_logins, NULLIF(w.total_attempts, 0))}} AS failure_rate_pct,
  w.distinct_identities AS distinct_emails_attempted,
  w.distinct_ips AS distinct_ips,
  {{divide_decimal(w.total_attempts * 1.0, NULLIF(w.distinct_ips, 0))}} AS avg_attempts_per_ip,
  m.max_ip_attempts AS max_attempts_single_ip
FROM weekly w
JOIN ip_max m ON m.week_start = w.week_start
ORDER BY w.week_start NULLS LAST
