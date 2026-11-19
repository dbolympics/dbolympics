SELECT
  seg AS segment,
  COUNT(*) AS customer_count,
  AVG(CAST(orders_90d AS NUMERIC(18,6))) AS avg_orders_90d,
  AVG(revenue_90d_eur) AS avg_revenue_90d_eur,
  100.0 * AVG(CASE WHEN orders_90d >= 2 THEN 1.0 ELSE 0.0 END) AS pct_2nd_order_within_90d,
  {{divide_decimal(100.0 * SUM(CASE WHEN orders_90d < 2 AND has_order_90_180 THEN 1 ELSE 0 END), NULLIF(SUM(CASE WHEN orders_90d < 2 THEN 1 ELSE 0 END), 0))}} AS pct_2nd_order_90_180d,
  {{divide_decimal(100.0 * SUM(refunded_orders_90d), NULLIF(SUM(orders_90d), 0))}} AS refund_rate_90d_pct
FROM (
  SELECT
    u.id AS user_id,
    CASE WHEN EXISTS (SELECT 1 FROM referral_redemptions rr WHERE rr.referred_user_id = u.id) THEN 'referred' ELSE 'other' END AS seg,
    fo.day0 AS day0,
    (SELECT COUNT(*) FROM orders o WHERE o.user_id = u.id AND o.placed_at IS NOT NULL AND o.placed_at >= fo.day0 AND o.placed_at < fo.day0 + INTERVAL '90 days') AS orders_90d,
    (SELECT COALESCE(SUM(CASE WHEN o.currency_code = 'EUR' THEN CAST(o.grand_total AS NUMERIC(18,6)) ELSE CAST({{divide_decimal(o.grand_total, NULLIF(er.rate, 0))}} AS NUMERIC(18,6)) END), 0)
       FROM orders o
       LEFT JOIN exchange_rates er ON er.base_code = 'EUR' AND er.quote_code = o.currency_code AND er.as_of = CAST(o.placed_at AS date)
       WHERE o.user_id = u.id AND o.placed_at IS NOT NULL AND o.placed_at >= fo.day0 AND o.placed_at < fo.day0 + INTERVAL '90 days'
    ) AS revenue_90d_eur,
    (SELECT COUNT(*) FROM orders o WHERE o.user_id = u.id AND o.placed_at IS NOT NULL AND o.placed_at >= fo.day0 AND o.placed_at < fo.day0 + INTERVAL '90 days'
       AND (EXISTS (SELECT 1 FROM payments p WHERE p.order_id = o.id AND p.amount_refunded > 0)
            OR EXISTS (SELECT 1 FROM order_returns r WHERE r.order_id = o.id))
    ) AS refunded_orders_90d,
    EXISTS (SELECT 1 FROM orders o WHERE o.user_id = u.id AND o.placed_at IS NOT NULL AND o.placed_at >= fo.day0 + INTERVAL '90 days' AND o.placed_at < fo.day0 + INTERVAL '180 days') AS has_order_90_180
  FROM users u
  JOIN (SELECT user_id, MIN(placed_at) AS day0 FROM orders WHERE placed_at IS NOT NULL GROUP BY user_id) fo ON fo.user_id = u.id
  WHERE u.is_staff = false
    AND CAST(u.created_at AS DATE) BETWEEN DATE '2023-01-01' AND DATE '2025-10-02'
) t
GROUP BY seg
ORDER BY CASE WHEN seg = 'referred' THEN 0 ELSE 1 END NULLS LAST, seg NULLS LAST
