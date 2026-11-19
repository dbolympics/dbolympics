WITH first_referral AS (
  SELECT tenant_id, referrer_user_id, MIN(created_at) AS first_referral_at
  FROM referrals
  GROUP BY tenant_id, referrer_user_id
),
referrer_orders AS (
  SELECT
    fr.tenant_id AS tenant_id,
    fr.referrer_user_id AS referrer_user_id,
    COUNT(CASE WHEN o.placed_at < fr.first_referral_at THEN 1 END) AS orders_before,
    COUNT(CASE WHEN o.placed_at >= DATE '2025-01-01' AND o.placed_at < DATE '2026-01-01' THEN 1 END) AS orders_2025
  FROM first_referral fr
  LEFT JOIN orders o
    ON o.tenant_id = fr.tenant_id AND o.user_id = fr.referrer_user_id
  GROUP BY fr.tenant_id, fr.referrer_user_id, fr.first_referral_at
)
SELECT
  bucket_label AS orders_before_first_referral_bucket,
  COUNT(*) AS referrer_count,
  {{divide_decimal(COUNT(*) * 100.0, SUM(COUNT(*)) OVER ())}} AS share_of_referrers_pct,
  AVG(CAST(orders_2025 AS NUMERIC(18,6))) AS avg_total_2025_orders
FROM (
  SELECT
    ro.orders_before AS orders_before,
    ro.orders_2025 AS orders_2025,
    CASE
      WHEN ro.orders_before = 0 THEN 0
      WHEN ro.orders_before = 1 THEN 1
      WHEN ro.orders_before = 2 THEN 2
      WHEN ro.orders_before = 3 THEN 3
      WHEN ro.orders_before BETWEEN 4 AND 5 THEN 4
      ELSE 6
    END AS sort_key,
    CASE
      WHEN ro.orders_before = 0 THEN '0 (referred before ordering)'
      WHEN ro.orders_before = 1 THEN '1'
      WHEN ro.orders_before = 2 THEN '2'
      WHEN ro.orders_before = 3 THEN '3'
      WHEN ro.orders_before BETWEEN 4 AND 5 THEN '4-5'
      ELSE '6+'
    END AS bucket_label
  FROM referrer_orders ro
) b
GROUP BY bucket_label, sort_key
ORDER BY sort_key NULLS LAST
