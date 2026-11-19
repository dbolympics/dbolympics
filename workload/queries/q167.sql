SELECT
  q.quarter AS quarter,
  (SELECT COUNT(DISTINCT o.user_id)
     FROM orders o
     JOIN users u ON u.id = o.user_id
    WHERE u.is_staff = false
      AND o.placed_at IS NOT NULL
      AND CAST(o.placed_at AS DATE) <= q.quarter_end) AS active_customers_cumulative,
  (SELECT COUNT(DISTINCT la.user_id)
     FROM loyalty_accounts la
     JOIN users u ON u.id = la.user_id
    WHERE u.is_staff = false
      AND CAST(la.enrolled_at AS DATE) <= q.quarter_end) AS loyalty_members_cumulative,
  {{divide_decimal(100.0 *
(SELECT COUNT(DISTINCT la.user_id)
 FROM loyalty_accounts la
 JOIN users u ON u.id = la.user_id
WHERE u.is_staff = false
  AND CAST(la.enrolled_at AS DATE) <= q.quarter_end), NULLIF((SELECT COUNT(DISTINCT o.user_id)
          FROM orders o
          JOIN users u ON u.id = o.user_id
         WHERE u.is_staff = false
           AND o.placed_at IS NOT NULL
           AND CAST(o.placed_at AS DATE) <= q.quarter_end), 0))}} AS pct_customers_loyalty_members,
  (SELECT COUNT(DISTINCT rr.referred_user_id)
     FROM referral_redemptions rr
     JOIN users u ON u.id = rr.referred_user_id
    WHERE u.is_staff = false
      AND CAST(rr.redeemed_at AS DATE) <= q.quarter_end) AS referred_customers_cumulative,
  {{divide_decimal(100.0 *
(SELECT COUNT(DISTINCT rr.referred_user_id)
 FROM referral_redemptions rr
 JOIN users u ON u.id = rr.referred_user_id
WHERE u.is_staff = false
  AND CAST(rr.redeemed_at AS DATE) <= q.quarter_end), NULLIF((SELECT COUNT(DISTINCT o.user_id)
          FROM orders o
          JOIN users u ON u.id = o.user_id
         WHERE u.is_staff = false
           AND o.placed_at IS NOT NULL
           AND CAST(o.placed_at AS DATE) <= q.quarter_end), 0))}} AS pct_customers_referred
FROM (
  SELECT
    year_num,
    quarter_num,
    CONCAT(CAST(year_num AS VARCHAR), '-Q', CAST(quarter_num AS VARCHAR)) AS quarter,
    MAX(calendar_date) AS quarter_end
  FROM calendar_days
  WHERE year_num BETWEEN 2023 AND 2025
  GROUP BY year_num, quarter_num
) q
ORDER BY q.year_num ASC NULLS LAST, q.quarter_num ASC NULLS LAST
