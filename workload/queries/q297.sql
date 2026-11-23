WITH t0 AS ( -- stalled carts: created in window, not converted within first hour
  SELECT
    c0.id AS cart_id,
    c0.tenant_id AS tenant_id,
    c0.user_id AS user_id,
    c0.created_at AS created_at
  FROM carts c0
  JOIN tenants t0t ON t0t.id = c0.tenant_id
  WHERE t0t.name IN (
      'Kibblewick', 'Studio Vrij', 'Petalcourt Beauty',
      'Marrowby & Vane', 'Cragsley Outfitters', 'Ampfeld Elektronik'
    )
    AND c0.created_at >= DATE '2025-01-01'
    AND c0.created_at < DATE '2025-12-01'
    AND NOT (
      c0.status = 'converted'
      AND c0.converted_at IS NOT NULL
      AND c0.converted_at <= c0.created_at + INTERVAL '1 hour'
    )
),
t1 AS ( -- distinct matched email_log rows per stalled cart owner, in the recovery window
  SELECT DISTINCT
    e1.id AS email_log_id,
    e1.template_id AS template_id
  FROM email_log e1
  JOIN t0 ON t0.tenant_id = e1.tenant_id
         AND t0.user_id = e1.user_id
         AND e1.sent_at >= t0.created_at + INTERVAL '1 hour'
         AND e1.sent_at <= t0.created_at + INTERVAL '48 hour'
),
t2 AS ( -- email counts per template (NULL template_id rows collapse into one 'ad hoc' group)
  SELECT
    t1.template_id AS template_id,
    COUNT(*) AS email_count
  FROM t1
  GROUP BY t1.template_id
),
t3 AS ( -- grand total of matched emails, for pct calc
  SELECT COUNT(*) AS total_matched
  FROM t1
)
SELECT
  COALESCE(nt.code, 'no template / ad hoc') AS template_code,
  COALESCE(nt.name, 'no template / ad hoc') AS template_name,
  COALESCE(nt.channel, 'n/a') AS channel,
  t2.email_count AS email_count,
  {{divide_decimal(100.0 * t2.email_count, NULLIF(t3.total_matched, 0))}} AS pct_of_matched_emails
FROM t2
CROSS JOIN t3
LEFT JOIN notification_templates nt ON nt.id = t2.template_id
ORDER BY t2.email_count DESC NULLS FIRST, template_code NULLS LAST, t2.template_id NULLS LAST
