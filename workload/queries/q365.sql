WITH matching_discounts AS (
  SELECT od.order_id AS order_id, od.tenant_id AS tenant_id, SUM(od.amount) AS total_discount_amount, MAX(od.currency_code) AS currency_code
  FROM order_discounts od
  JOIN discounts d ON d.id = od.discount_id AND d.tenant_id = od.tenant_id
  WHERE d.name = 'Subscription delivery (prepaid)'
  GROUP BY od.order_id, od.tenant_id
),
orphan_orders AS (
  SELECT
    o.id AS order_id,
    o.tenant_id AS tenant_id,
    o.user_id AS user_id,
    o.placed_at AS placed_at,
    s.started_at AS sub_started_at,
    s.ended_at AS sub_ended_at,
    md.total_discount_amount AS total_discount_amount,
    md.currency_code AS currency_code
  FROM orders o
  JOIN matching_discounts md ON md.order_id = o.id AND md.tenant_id = o.tenant_id
  JOIN LATERAL (
    SELECT sub.*
    FROM subscriptions sub
    WHERE sub.user_id = o.user_id AND sub.tenant_id = o.tenant_id
    ORDER BY sub.started_at DESC NULLS FIRST, sub.id DESC NULLS FIRST
    {{fetch_first(1)}}
  ) s ON true
  WHERE o.status <> 'cancelled'
    AND o.placed_at >= DATE '2025-01-01' AND o.placed_at < DATE '2026-01-01'
    AND s.status = 'active'
    AND NOT EXISTS (
      SELECT 1 FROM subscriptions sub2
      WHERE sub2.user_id = o.user_id AND sub2.tenant_id = o.tenant_id
        AND sub2.status IN ('active','trialing','past_due')
        AND sub2.started_at <= o.placed_at
        AND (sub2.ended_at IS NULL OR sub2.ended_at >= o.placed_at)
    )
),
classified AS (
  SELECT
    oo.*,
    CASE
      WHEN sub_started_at > placed_at THEN 'subscription started after this order'
      WHEN sub_started_at <= placed_at AND sub_ended_at IS NOT NULL AND sub_ended_at < placed_at THEN 'active status but already past its end date'
      ELSE 'dates indicate overlap - likely a bug in the original orphan flag'
    END AS category,
    CAST({{divide_decimal(total_discount_amount, er.rate)}} AS NUMERIC(18,6)) AS discount_amount_eur
  FROM orphan_orders oo
  LEFT JOIN exchange_rates er
    ON er.base_code = 'EUR'
   AND er.quote_code = oo.currency_code
   AND er.as_of = CAST(oo.placed_at AS DATE)
)
SELECT
  category,
  COUNT(*) AS order_count,
  {{divide_decimal(100.0 * COUNT(*), SUM(COUNT(*)) OVER ())}} AS pct_of_bucket,
  COUNT(DISTINCT user_id) AS distinct_customers,
  SUM(discount_amount_eur) AS total_discount_eur,
  SUM(COUNT(*)) OVER () AS check_total_291
FROM classified
GROUP BY category
ORDER BY order_count DESC NULLS FIRST, category NULLS LAST
