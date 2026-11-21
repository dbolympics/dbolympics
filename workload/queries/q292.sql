WITH six_tenants AS (
  SELECT id FROM tenants
  WHERE name IN ('Kibblewick','Studio Vrij','Petalcourt Beauty','Marrowby & Vane','Cragsley Outfitters','Ampfeld Elektronik')
),
population AS (
  SELECT c.id AS id, c.tenant_id AS tenant_id, c.user_id AS user_id, c.status AS status, c.converted_at AS converted_at, c.created_at AS created_at
  FROM carts c
  JOIN six_tenants st ON st.id = c.tenant_id
  WHERE c.created_at >= DATE '2025-01-01'
    AND c.created_at < DATE '2025-12-01'
    AND NOT (c.status = 'converted' AND c.converted_at IS NOT NULL AND c.converted_at <= c.created_at + INTERVAL '1 hour')
),
grouped AS (
  SELECT p.*,
    CASE WHEN p.user_id IS NOT NULL AND EXISTS (
      SELECT 1 FROM email_log e
      WHERE e.tenant_id = p.tenant_id
        AND e.user_id = p.user_id
        AND e.sent_at > p.created_at + INTERVAL '1 hour'
        AND e.sent_at <= p.created_at + INTERVAL '48 hour'
    ) THEN 'received_email' ELSE 'no_email' END AS grp
  FROM population p
),
agg AS (
  SELECT grp,
    COUNT(*) AS cart_count,
    COUNT(*) FILTER (WHERE user_id IS NULL) AS guest_cart_count,
    COUNT(*) FILTER (WHERE status = 'converted') AS converted_count
  FROM grouped
  GROUP BY grp
),
medians AS (
  SELECT grp,
    {{percentile_cont(0.5, {{divide_decimal({{seconds_between(created_at, converted_at)}}, 86400.0)}})}} AS median_days_to_convert
  FROM grouped
  WHERE status = 'converted'
  GROUP BY grp
)
SELECT
  a.grp AS group_name,
  a.cart_count AS cart_count,
  a.guest_cart_count AS guest_cart_count,
  {{divide_decimal(100.0 * a.converted_count, a.cart_count)}} AS pct_eventually_converted,
  m.median_days_to_convert AS median_days_to_convert
FROM agg a
LEFT JOIN medians m ON m.grp = a.grp
ORDER BY CASE WHEN a.grp = 'received_email' THEN 0 ELSE 1 END NULLS LAST, a.grp NULLS LAST
