WITH user_orders AS (
  SELECT
    tenant_id,
    user_id,
    MAX(placed_at) AS last_order_at,
    COUNT(*) AS order_count
  FROM orders
  WHERE status <> 'cancelled'
  GROUP BY tenant_id, user_id
),
classified AS (
  SELECT
    tenant_id,
    user_id,
    CASE
      WHEN order_count >= 3
        AND CAST(last_order_at AS date) <= DATE '2025-12-31' - INTERVAL '180 days'
        AND CAST(last_order_at AS date) >= DATE '2025-12-31' - INTERVAL '365 days'
        THEN 'lapsed'
      WHEN order_count >= 3
        AND CAST(last_order_at AS date) > DATE '2025-12-31' - INTERVAL '90 days'
        AND CAST(last_order_at AS date) <= DATE '2025-12-31'
        THEN 'active'
      ELSE NULL
    END AS shopper_group,
    CASE
      WHEN order_count >= 3
        AND CAST(last_order_at AS date) <= DATE '2025-12-31' - INTERVAL '180 days'
        AND CAST(last_order_at AS date) >= DATE '2025-12-31' - INTERVAL '365 days'
        THEN CAST(last_order_at AS date)
      WHEN order_count >= 3
        AND CAST(last_order_at AS date) > DATE '2025-12-31' - INTERVAL '90 days'
        AND CAST(last_order_at AS date) <= DATE '2025-12-31'
        THEN DATE '2025-12-31'
      ELSE NULL
    END AS reference_date
  FROM user_orders
),
eligible AS (
  SELECT tenant_id, user_id, shopper_group, reference_date
  FROM classified
  WHERE shopper_group IS NOT NULL
),
messages AS (
  SELECT
    e.shopper_group AS shopper_group,
    e.tenant_id AS tenant_id,
    e.user_id AS user_id,
    CASE
      WHEN (e.reference_date - CAST(cm.sent_at AS date)) BETWEEN 0 AND 90 THEN '0-90 days before reference'
      WHEN (e.reference_date - CAST(cm.sent_at AS date)) BETWEEN 91 AND 180 THEN '91-180 days before reference'
      ELSE NULL
    END AS window_label,
    cm.opened_at AS opened_at,
    cm.clicked_at AS clicked_at
  FROM eligible e
  JOIN campaign_messages cm
    ON cm.tenant_id = e.tenant_id
   AND cm.user_id = e.user_id
   AND cm.sent_at IS NOT NULL
)
SELECT
  shopper_group,
  window_label AS window_before_reference,
  COUNT(DISTINCT tenant_id || '-' || user_id) AS shopper_count,
  COUNT(*) AS messages_sent,
  COUNT(opened_at) AS messages_opened,
  {{divide_decimal(100.0 * COUNT(opened_at), NULLIF(COUNT(*), 0))}} AS open_rate_pct,
  COUNT(clicked_at) AS messages_clicked,
  {{divide_decimal(100.0 * COUNT(clicked_at), NULLIF(COUNT(*), 0))}} AS click_rate_pct
FROM messages
WHERE window_label IS NOT NULL
GROUP BY shopper_group, window_label
ORDER BY shopper_group NULLS LAST, window_label NULLS LAST
