WITH base AS (
  SELECT
    c.id AS id,
    c.status AS status,
    c.created_at AS created_at,
    c.converted_at AS converted_at,
    c.abandoned_at AS abandoned_at,
    c.expires_at AS expires_at,
    CASE
      WHEN c.converted_at IS NOT NULL OR c.abandoned_at IS NOT NULL OR c.expires_at IS NOT NULL
      THEN {{divide_decimal({{seconds_between(c.created_at, COALESCE(c.converted_at, c.abandoned_at, c.expires_at))}}, 3600.0)}}
      ELSE NULL
    END AS resolution_hours
  FROM carts c
  JOIN tenants t ON t.id = c.tenant_id
  WHERE t.name IN ('Kibblewick', 'Studio Vrij', 'Petalcourt Beauty', 'Marrowby & Vane', 'Cragsley Outfitters', 'Ampfeld Elektronik')
    AND c.created_at >= DATE '2025-10-01'
    AND c.created_at < DATE '2026-01-01'
),
bucketed AS (
  SELECT
    *,
    CASE
      WHEN resolution_hours IS NULL THEN 'unresolved/still active'
      WHEN resolution_hours < 1 THEN '<1 hour'
      WHEN resolution_hours < 24 THEN '1-24 hours'
      WHEN resolution_hours < 168 THEN '1-7 days'
      ELSE '>7 days'
    END AS duration_bucket
  FROM base
)
SELECT
  duration_bucket,
  COUNT(*) AS cart_count,
  {{divide_decimal(COUNT(*) * 100.0, SUM(COUNT(*)) OVER ())}} AS pct_of_carts,
  {{divide_decimal(SUM(CASE WHEN status = 'converted' THEN 1 ELSE 0 END) * 100.0, COUNT(*))}} AS converted_pct
FROM bucketed
GROUP BY duration_bucket
ORDER BY
  CASE duration_bucket
    WHEN '<1 hour' THEN 1
    WHEN '1-24 hours' THEN 2
    WHEN '1-7 days' THEN 3
    WHEN '>7 days' THEN 4
    WHEN 'unresolved/still active' THEN 5
  END NULLS LAST
