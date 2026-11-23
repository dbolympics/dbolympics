WITH messages AS (
  SELECT
    cm.sent_at AS sent_at,
    cm.delivered_at AS delivered_at,
    cm.opened_at AS opened_at,
    cm.clicked_at AS clicked_at,
    cm.bounced_at AS bounced_at,
    cm.unsubscribed_at AS unsubscribed_at,
    c.channel AS channel
  FROM campaign_messages cm
  JOIN campaigns c ON c.id = cm.campaign_id
  WHERE cm.created_at >= DATE '2025-01-01'
    AND cm.created_at < DATE '2026-01-01'
),
agg AS (
  SELECT
    channel,
    COUNT(*) FILTER (WHERE sent_at IS NOT NULL) AS messages_sent,
    COUNT(*) FILTER (WHERE delivered_at IS NOT NULL) AS delivered_count,
    COUNT(*) FILTER (WHERE delivered_at IS NOT NULL AND opened_at IS NOT NULL) AS opened_count,
    COUNT(*) FILTER (WHERE delivered_at IS NOT NULL AND clicked_at IS NOT NULL) AS clicked_count,
    COUNT(*) FILTER (WHERE sent_at IS NOT NULL AND bounced_at IS NOT NULL) AS bounced_count,
    COUNT(*) FILTER (WHERE sent_at IS NOT NULL AND unsubscribed_at IS NOT NULL) AS unsubscribed_count
  FROM messages
  GROUP BY channel
)
SELECT
  channel,
  messages_sent,
  {{divide_decimal(100.0 * delivered_count, NULLIF(messages_sent, 0))}} AS delivered_rate_pct,
  {{divide_decimal(100.0 * opened_count, NULLIF(delivered_count, 0))}} AS open_rate_pct,
  {{divide_decimal(100.0 * clicked_count, NULLIF(delivered_count, 0))}} AS click_rate_pct,
  {{divide_decimal(100.0 * bounced_count, NULLIF(messages_sent, 0))}} AS bounce_rate_pct,
  {{divide_decimal(100.0 * unsubscribed_count, NULLIF(messages_sent, 0))}} AS unsubscribe_rate_pct
FROM agg
ORDER BY messages_sent DESC NULLS FIRST, channel ASC NULLS LAST
