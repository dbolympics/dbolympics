WITH months AS (
  SELECT month_label, MIN(calendar_date) AS month_start, MAX(calendar_date) AS month_end
  FROM calendar_days
  WHERE calendar_date BETWEEN DATE '2023-01-01' AND DATE '2025-12-31'
  GROUP BY month_label
),
flow AS (
  SELECT cd.month_label AS month_label,
         SUM(CASE WHEN cr.status = 'granted' THEN 1 ELSE 0 END) AS grants,
         SUM(CASE WHEN cr.status = 'withdrawn' THEN 1 ELSE 0 END) AS withdrawals,
         SUM(CASE WHEN cr.status = 'expired' THEN 1 ELSE 0 END) AS expirations
  FROM calendar_days cd
  JOIN consent_records cr
    ON CAST(cr.occurred_at AS date) = cd.calendar_date
   AND cr.purpose = 'marketing_email'
  WHERE cd.calendar_date BETWEEN DATE '2023-01-01' AND DATE '2025-12-31'
  GROUP BY cd.month_label
),
snapshot_base AS (
  SELECT m.month_label AS month_label,
         cr.user_id AS user_id,
         cr.status AS status,
         ROW_NUMBER() OVER (PARTITION BY m.month_label, cr.user_id ORDER BY cr.occurred_at DESC NULLS FIRST, cr.id DESC NULLS FIRST) AS rn
  FROM months m
  JOIN consent_records cr
    ON cr.purpose = 'marketing_email'
   AND cr.occurred_at < (m.month_end + INTERVAL '1 day')
),
monthly_active AS (
  SELECT month_label,
         COUNT(*) AS users_with_consent,
         SUM(CASE WHEN status = 'granted' THEN 1 ELSE 0 END) AS net_active
  FROM snapshot_base
  WHERE rn = 1
  GROUP BY month_label
)
SELECT
  m.month_label AS month,
  COALESCE(f.grants, 0) AS grants_recorded,
  COALESCE(f.withdrawals, 0) AS withdrawals_recorded,
  COALESCE(f.expirations, 0) AS expirations_recorded,
  COALESCE(ma.users_with_consent, 0) AS users_with_any_consent,
  COALESCE(ma.net_active, 0) AS net_active_opt_ins,
  {{divide_decimal(100.0 * COALESCE(ma.net_active, 0), NULLIF(ma.users_with_consent, 0))}} AS active_opt_in_rate_pct
FROM months m
LEFT JOIN flow f ON f.month_label = m.month_label
LEFT JOIN monthly_active ma ON ma.month_label = m.month_label
ORDER BY m.month_label ASC NULLS LAST
