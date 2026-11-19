SELECT
  COUNT(DISTINCT w.user_key) AS withdrawn_users,
  COUNT(DISTINCT CASE WHEN cm.id IS NOT NULL THEN w.user_key END) AS contacted_after_withdrawal_users,
  {{divide_decimal(100.0 * COUNT(DISTINCT CASE WHEN cm.id IS NOT NULL THEN w.user_key END), NULLIF(COUNT(DISTINCT w.user_key), 0))}} AS pct_contacted_after_withdrawal,
  COUNT(cm.id) AS total_post_withdrawal_sends,
  MAX({{date_diff_days(w.withdrawn_at, COALESCE(cm.sent_at, cm.created_at))}}) AS max_days_withdrawal_to_send,
  MAX(COALESCE(cm.sent_at, cm.created_at)) AS most_recent_post_withdrawal_send
FROM (
  SELECT
    tenant_id,
    user_id,
    occurred_at AS withdrawn_at,
    ROW_NUMBER() OVER (ORDER BY tenant_id NULLS LAST, user_id NULLS LAST) AS user_key
  FROM (
    SELECT
      tenant_id,
      user_id,
      status,
      occurred_at,
      ROW_NUMBER() OVER (PARTITION BY tenant_id, user_id ORDER BY occurred_at DESC NULLS FIRST, id DESC NULLS FIRST) AS rn
    FROM consent_records
    WHERE purpose = 'marketing_email'
  ) ranked
  WHERE rn = 1 AND status = 'withdrawn'
) w
LEFT JOIN campaign_messages cm
  ON cm.tenant_id = w.tenant_id
  AND cm.user_id = w.user_id
  AND COALESCE(cm.sent_at, cm.created_at) > w.withdrawn_at
ORDER BY withdrawn_users NULLS LAST
