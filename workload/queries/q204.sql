WITH macro_totals AS (
  SELECT COUNT(*) AS total_macro_count, SUM(usage_count) AS total_macro_usage_sum
  FROM macros
  WHERE deleted_at IS NULL
),
agent_reply_totals AS (
  SELECT COUNT(*) AS total_agent_reply_messages_2025
  FROM ticket_messages
  WHERE is_public = true
    AND author_agent_id IS NOT NULL
    AND created_at >= DATE '2025-01-01'
    AND created_at < DATE '2026-01-01'
)
SELECT
  m.title AS macro_title,
  m.is_shared AS is_shared,
  m.usage_count AS usage_count,
  {{divide_decimal(100.0 * m.usage_count, NULLIF(mt.total_macro_usage_sum, 0))}} AS pct_of_total_macro_usage,
  mt.total_macro_count AS total_macro_count,
  mt.total_macro_usage_sum AS total_macro_usage_sum,
  art.total_agent_reply_messages_2025 AS total_agent_reply_messages_2025
FROM macros m
CROSS JOIN macro_totals mt
CROSS JOIN agent_reply_totals art
WHERE m.deleted_at IS NULL
ORDER BY m.usage_count DESC NULLS FIRST, m.title ASC NULLS LAST, m.id ASC NULLS LAST
{{fetch_first(20)}}
