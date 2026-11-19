SELECT
  metrics.purpose AS purpose,
  metrics.month_label AS month,
  metrics.grants_recorded AS grants_recorded,
  metrics.withdrawals_recorded AS withdrawals_recorded,
  metrics.expirations_recorded AS expirations_recorded,
  metrics.users_with_any_record AS users_with_any_record,
  metrics.net_active_optins AS net_active_optins,
  CASE WHEN metrics.users_with_any_record = 0 THEN NULL
       ELSE {{divide_decimal(100.0 * metrics.net_active_optins, metrics.users_with_any_record)}}
  END AS active_optin_rate_pct
FROM (
  SELECT
    p.purpose AS purpose,
    m.month_start AS month_start,
    m.month_label AS month_label,
    m.month_end AS month_end,
    (SELECT COUNT(*) FROM consent_records cr
      WHERE cr.purpose = p.purpose AND cr.status = 'granted'
        AND CAST(cr.occurred_at AS DATE) BETWEEN m.month_start AND m.month_end) AS grants_recorded,
    (SELECT COUNT(*) FROM consent_records cr
      WHERE cr.purpose = p.purpose AND cr.status = 'withdrawn'
        AND CAST(cr.occurred_at AS DATE) BETWEEN m.month_start AND m.month_end) AS withdrawals_recorded,
    (SELECT COUNT(*) FROM consent_records cr
      WHERE cr.purpose = p.purpose AND cr.status = 'expired'
        AND CAST(cr.occurred_at AS DATE) BETWEEN m.month_start AND m.month_end) AS expirations_recorded,
    (SELECT COUNT(DISTINCT cr.user_id) FROM consent_records cr
      WHERE cr.purpose = p.purpose AND CAST(cr.occurred_at AS DATE) <= m.month_end) AS users_with_any_record,
    (SELECT COUNT(*) FROM (
        SELECT cr.user_id AS user_id, cr.status AS status,
               ROW_NUMBER() OVER (PARTITION BY cr.tenant_id, cr.user_id, cr.purpose ORDER BY cr.occurred_at DESC NULLS FIRST, cr.id DESC NULLS FIRST) AS rn
        FROM consent_records cr
        WHERE cr.purpose = p.purpose AND CAST(cr.occurred_at AS DATE) <= m.month_end
     ) ranked WHERE ranked.rn = 1 AND ranked.status = 'granted') AS net_active_optins
  FROM (SELECT DISTINCT purpose FROM consent_records) p
  CROSS JOIN (
    SELECT month_start, month_label, MAX(calendar_date) AS month_end
    FROM calendar_days
    WHERE year_num BETWEEN 2023 AND 2025
    GROUP BY month_start, month_label
  ) m
) metrics
ORDER BY metrics.purpose NULLS LAST, metrics.month_start NULLS LAST, metrics.month_label NULLS LAST
