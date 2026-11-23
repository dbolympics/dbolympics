WITH base_carts AS (
  SELECT c.tenant_id AS tenant_id, c.user_id AS user_id, c.status AS status, c.created_at AS created_at, c.converted_at AS converted_at,
    EXISTS (
      SELECT 1 FROM email_log e
      WHERE e.tenant_id = c.tenant_id
        AND e.user_id = c.user_id
        AND e.sent_at >= c.created_at + INTERVAL '1 hour'
        AND e.sent_at <= c.created_at + INTERVAL '48 hour'
    ) AS has_email
  FROM carts c
  JOIN tenants t ON t.id = c.tenant_id
  WHERE t.name IN ('Kibblewick','Studio Vrij','Petalcourt Beauty','Marrowby & Vane','Cragsley Outfitters','Ampfeld Elektronik')
    AND c.created_at >= DATE '2025-01-01'
    AND c.created_at < DATE '2025-12-01'
    AND NOT (c.status = 'converted' AND c.converted_at IS NOT NULL AND c.converted_at <= c.created_at + INTERVAL '1 hour')
),
grouped AS (
  SELECT
    CASE
      WHEN user_id IS NULL THEN 'guest'
      WHEN has_email THEN 'received_email'
      ELSE 'logged_in_no_email'
    END AS group_name,
    status,
    converted_at,
    created_at
  FROM base_carts
)
SELECT
  group_name AS "group",
  COUNT(*) AS cart_count,
  {{divide_decimal(100.0 * COUNT(*) FILTER (WHERE status = 'converted'), COUNT(*))}} AS pct_eventually_converted,
  {{percentile_cont_filter(0.5, {{divide_decimal({{seconds_between(created_at, converted_at)}}, 86400.0)}}, status = 'converted')}} AS median_days_to_convert
FROM grouped
GROUP BY group_name
ORDER BY CASE group_name WHEN 'received_email' THEN 1 WHEN 'logged_in_no_email' THEN 2 WHEN 'guest' THEN 3 END NULLS LAST
