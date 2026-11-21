WITH base AS (
  SELECT t.id AS tenant_id, t.name AS tenant_name, c.year_num AS year_num, c.quarter_num AS quarter_num
  FROM tenants t
  CROSS JOIN (
    SELECT DISTINCT year_num, quarter_num
    FROM calendar_days
    WHERE calendar_date BETWEEN DATE '2023-01-01' AND DATE '2025-12-31'
  ) c
  WHERE t.name IN ('Cragsley Outfitters', 'Marrowby & Vane', 'Studio Vrij')
)
SELECT
  b.tenant_name AS tenant_name,
  b.year_num || '-Q' || b.quarter_num AS quarter,
  COALESCE(ta.total_attempts, 0) AS total_attempts,
  COALESCE(fa.failed_attempts, 0) AS failed_attempts,
  CASE
    WHEN COALESCE(ta.total_attempts, 0) = 0 THEN 0
    ELSE {{divide_decimal(100.0 * COALESCE(fa.failed_attempts, 0), ta.total_attempts)}}
  END AS pct_failed
FROM base b
LEFT JOIN (
  SELECT la.tenant_id AS tenant_id, cd.year_num AS year_num, cd.quarter_num AS quarter_num, COUNT(*) AS total_attempts
  FROM login_attempts la
  JOIN calendar_days cd ON cd.calendar_date = CAST(la.occurred_at AS DATE)
  GROUP BY la.tenant_id, cd.year_num, cd.quarter_num
) ta ON ta.tenant_id = b.tenant_id AND ta.year_num = b.year_num AND ta.quarter_num = b.quarter_num
LEFT JOIN (
  SELECT la.tenant_id AS tenant_id, cd.year_num AS year_num, cd.quarter_num AS quarter_num, COUNT(*) AS failed_attempts
  FROM login_attempts la
  JOIN calendar_days cd ON cd.calendar_date = CAST(la.occurred_at AS DATE)
  WHERE la.succeeded = false
  GROUP BY la.tenant_id, cd.year_num, cd.quarter_num
) fa ON fa.tenant_id = b.tenant_id AND fa.year_num = b.year_num AND fa.quarter_num = b.quarter_num
ORDER BY b.tenant_name NULLS LAST, b.year_num NULLS LAST, b.quarter_num NULLS LAST, b.tenant_id NULLS LAST
