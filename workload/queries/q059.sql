WITH classified AS (
  SELECT o.id AS order_id, o.tenant_id AS tenant_id, o.user_id AS user_id, o.grand_total AS grand_total, o.currency_code AS currency_code, o.placed_at AS placed_at,
    CASE WHEN rr.referred_user_id IS NOT NULL THEN 'referred'
         WHEN rf.referrer_user_id IS NOT NULL THEN 'referrer'
         ELSE 'neither' END AS segment
  FROM orders o
  LEFT JOIN (SELECT DISTINCT tenant_id, referred_user_id FROM referral_redemptions) rr
    ON rr.tenant_id = o.tenant_id AND rr.referred_user_id = o.user_id
  LEFT JOIN (SELECT DISTINCT tenant_id, referrer_user_id FROM referrals) rf
    ON rf.tenant_id = o.tenant_id AND rf.referrer_user_id = o.user_id
  WHERE o.placed_at >= DATE '2025-01-01' AND o.placed_at < DATE '2026-01-01'
),
converted AS (
  SELECT c.*,
    CASE WHEN c.currency_code = 'EUR' THEN c.grand_total
         ELSE CAST({{divide_decimal(c.grand_total, er.rate)}} AS NUMERIC(18,6)) END AS grand_total_eur
  FROM classified c
  LEFT JOIN exchange_rates er ON er.base_code = 'EUR' AND er.quote_code = c.currency_code AND er.as_of = CAST(c.placed_at AS date)
)
SELECT segment,
  COUNT(DISTINCT tenant_id || ':' || user_id) AS users_count,
  COUNT(*) AS orders_count_2025,
  {{divide_decimal(CAST(COUNT(*) AS numeric(18,6)), NULLIF(COUNT(DISTINCT tenant_id || ':' || user_id),0))}} AS avg_orders_per_user,
  AVG(grand_total_eur) AS avg_order_value_eur,
  SUM(grand_total_eur) AS total_revenue_eur
FROM converted
GROUP BY segment
ORDER BY CASE segment WHEN 'referred' THEN 1 WHEN 'referrer' THEN 2 ELSE 3 END NULLS LAST
