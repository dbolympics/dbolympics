WITH months AS (
  SELECT DISTINCT month_label, month_start
  FROM calendar_days
  WHERE calendar_date BETWEEN DATE '2023-01-01' AND DATE '2025-12-31'
),
login_month AS (
  SELECT CAST({{date_trunc('month', occurred_at)}} AS date) AS month_start,
         email,
         succeeded
  FROM login_attempts
),
login_agg AS (
  SELECT month_start,
         COUNT(*) AS total_login_attempts,
         COUNT(*) FILTER (WHERE succeeded = false) AS failed_login_attempts
  FROM login_month
  GROUP BY month_start
),
brute_force AS (
  SELECT month_start, COUNT(DISTINCT email) AS emails_with_5plus_failed
  FROM (
    SELECT month_start, email, COUNT(*) AS cnt
    FROM login_month
    WHERE succeeded = false AND email IS NOT NULL
    GROUP BY month_start, email
    HAVING COUNT(*) >= 5
  ) t
  GROUP BY month_start
),
audit_combined AS (
  SELECT occurred_at, action FROM audit_log WHERE action = 'access_denied'
  UNION ALL
  SELECT occurred_at, action FROM audit_log_archive WHERE action = 'access_denied'
),
audit_agg AS (
  SELECT CAST({{date_trunc('month', occurred_at)}} AS date) AS month_start,
         COUNT(*) AS audit_access_denied_events
  FROM audit_combined
  GROUP BY month_start
)
SELECT
  m.month_label AS month,
  COALESCE(la.total_login_attempts, 0) AS total_login_attempts,
  COALESCE(la.failed_login_attempts, 0) AS failed_login_attempts,
  CASE WHEN COALESCE(la.total_login_attempts,0) = 0 THEN 0
 ELSE 100.0 * la.failed_login_attempts / la.total_login_attempts END AS pct_failed,
  COALESCE(bf.emails_with_5plus_failed, 0) AS emails_with_5plus_failed_in_month,
  COALESCE(aa.audit_access_denied_events, 0) AS audit_access_denied_events
FROM months m
LEFT JOIN login_agg la ON la.month_start = m.month_start
LEFT JOIN brute_force bf ON bf.month_start = m.month_start
LEFT JOIN audit_agg aa ON aa.month_start = m.month_start
ORDER BY m.month_start NULLS LAST, m.month_label NULLS LAST
