SELECT
  cr.purpose AS purpose,
  COUNT(*) AS total_records,
  COUNT(DISTINCT cr.user_id) AS distinct_users,
  COUNT(*) FILTER (WHERE cr.status = 'granted') AS granted_count,
  COUNT(*) FILTER (WHERE cr.status = 'withdrawn') AS withdrawn_count,
  COUNT(*) FILTER (WHERE cr.status = 'expired') AS expired_count,
  {{divide_decimal(100.0 * (
    SELECT COUNT(DISTINCT sub.user_id)
    FROM consent_records sub
    WHERE sub.purpose = cr.purpose
      AND sub.status IN ('withdrawn', 'expired')
  ), NULLIF(COUNT(DISTINCT cr.user_id), 0))}} AS pct_users_ever_withdrawn_or_expired,
  MIN(cr.occurred_at) AS earliest_occurred_at,
  MAX(cr.occurred_at) AS latest_occurred_at
FROM consent_records cr
GROUP BY cr.purpose
ORDER BY total_records DESC NULLS FIRST, cr.purpose NULLS LAST
