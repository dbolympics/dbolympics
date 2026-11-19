WITH apparel_tenants AS (
  SELECT id AS tenant_id
  FROM tenants
  WHERE industry = 'Apparel & Footwear'
),
qualifying_users AS (
  SELECT u.id AS user_id, u.created_at AS created_at
  FROM users u
  JOIN apparel_tenants t ON t.tenant_id = u.tenant_id
  WHERE u.is_staff = false
    AND EXISTS (
      SELECT 1 FROM orders o
      WHERE o.user_id = u.id
        AND o.placed_at >= DATE '2023-01-01'
        AND o.placed_at < DATE '2026-01-01'
    )
),
order_agg AS (
  SELECT
    o.user_id AS user_id,
    COUNT(*) AS total_order_count,
    COUNT(*) FILTER (WHERE o.status <> 'cancelled') AS non_cancelled_order_count,
    SUM(CASE WHEN o.status <> 'cancelled' THEN CAST({{divide_decimal(o.grand_total, er.rate)}} AS NUMERIC(18,6)) ELSE 0 END) AS total_revenue_eur,
    COUNT(*) FILTER (
      WHERE EXISTS (SELECT 1 FROM payments p WHERE p.order_id = o.id AND p.amount_refunded > 0)
         OR EXISTS (SELECT 1 FROM order_returns r WHERE r.order_id = o.id)
    ) AS refunded_order_count
  FROM orders o
  JOIN qualifying_users qu ON qu.user_id = o.user_id
  LEFT JOIN exchange_rates er
    ON er.base_code = 'EUR'
   AND er.quote_code = o.currency_code
   AND er.as_of = CAST(COALESCE(o.placed_at, o.created_at) AS date)
  GROUP BY o.user_id
),
segmented AS (
  SELECT
    qu.user_id AS user_id,
    CASE
      WHEN EXISTS (SELECT 1 FROM loyalty_accounts la WHERE la.user_id = qu.user_id)
      THEN 'loyalty member' ELSE 'non-member'
    END AS segment,
    CASE
      WHEN qu.created_at > DATE '2025-12-31' - INTERVAL '6 months' THEN 'under 6 months'
      WHEN qu.created_at > DATE '2025-12-31' - INTERVAL '12 months' THEN '6 to 12 months'
      WHEN qu.created_at > DATE '2025-12-31' - INTERVAL '24 months' THEN '12 to 24 months'
      ELSE 'over 24 months'
    END AS tenure_band
  FROM qualifying_users qu
)
SELECT
  s.tenure_band AS tenure_band,
  s.segment AS segment,
  COUNT(*) AS customer_count,
  AVG(CAST(oa.total_order_count AS NUMERIC(18,6))) AS avg_lifetime_orders,
  AVG(oa.total_revenue_eur) AS avg_lifetime_revenue_eur,
  {{divide_decimal(SUM(oa.total_revenue_eur), NULLIF(SUM(oa.non_cancelled_order_count), 0))}} AS avg_order_value_eur,
  {{divide_decimal(100.0 * SUM(oa.refunded_order_count), NULLIF(SUM(oa.total_order_count), 0))}} AS refund_rate_pct
FROM segmented s
JOIN order_agg oa ON oa.user_id = s.user_id
GROUP BY s.tenure_band, s.segment
ORDER BY
  CASE s.tenure_band
    WHEN 'under 6 months' THEN 1
    WHEN '6 to 12 months' THEN 2
    WHEN '12 to 24 months' THEN 3
    WHEN 'over 24 months' THEN 4
  END NULLS LAST,
  CASE s.segment WHEN 'loyalty member' THEN 1 ELSE 2 END NULLS LAST
