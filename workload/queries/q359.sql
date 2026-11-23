WITH orphan_orders AS (
  SELECT o.id AS order_id, o.tenant_id AS tenant_id, o.user_id AS user_id, o.placed_at AS placed_at, od.amount AS discount_amount, od.currency_code AS discount_currency_code
  FROM orders o
  JOIN order_discounts od ON od.order_id = o.id AND od.tenant_id = o.tenant_id
  JOIN discounts d ON d.id = od.discount_id AND d.tenant_id = o.tenant_id
  WHERE d.name = 'Subscription delivery (prepaid)'
    AND o.placed_at >= DATE '2025-01-01'
    AND o.placed_at < DATE '2026-01-01'
    AND o.status <> 'cancelled'
    AND NOT EXISTS (
      SELECT 1 FROM subscriptions s0
      WHERE s0.tenant_id = o.tenant_id
        AND s0.user_id = o.user_id
        AND s0.status IN ('trialing','active','past_due')
        AND s0.started_at <= o.placed_at
        AND (s0.ended_at IS NULL OR s0.ended_at >= o.placed_at)
    )
),
most_recent_sub AS (
  SELECT tenant_id, user_id, sub_id, status
  FROM (
    SELECT s.tenant_id AS tenant_id, s.user_id AS user_id, s.id AS sub_id, s.status AS status,
           ROW_NUMBER() OVER (PARTITION BY s.tenant_id, s.user_id ORDER BY s.started_at DESC NULLS FIRST, s.id DESC NULLS FIRST) AS rn
    FROM subscriptions s
  ) ranked
  WHERE rn = 1
),
active_bucket_orders AS (
  SELECT oo.order_id AS order_id, oo.tenant_id AS tenant_id, oo.user_id AS user_id, oo.placed_at AS placed_at,
         oo.discount_amount AS discount_amount, oo.discount_currency_code AS discount_currency_code,
         mrs.sub_id AS most_recent_sub_id
  FROM orphan_orders oo
  JOIN most_recent_sub mrs
    ON mrs.tenant_id = oo.tenant_id AND mrs.user_id = oo.user_id
  WHERE mrs.status = 'active'
),
older_sub_candidates AS (
  SELECT abo.order_id AS order_id, s.id AS older_sub_id, s.started_at AS older_started_at, s.ended_at AS older_ended_at,
         ROW_NUMBER() OVER (PARTITION BY abo.order_id ORDER BY s.started_at DESC NULLS FIRST, s.id DESC NULLS FIRST) AS rn
  FROM active_bucket_orders abo
  JOIN subscriptions s
    ON s.tenant_id = abo.tenant_id
   AND s.user_id = abo.user_id
   AND s.id <> abo.most_recent_sub_id
   AND s.started_at <= abo.placed_at
),
older_sub_pick AS (
  SELECT order_id, older_sub_id, older_started_at, older_ended_at
  FROM older_sub_candidates
  WHERE rn = 1
),
classified AS (
  SELECT
    abo.order_id AS order_id,
    abo.tenant_id AS tenant_id,
    abo.user_id AS user_id,
    abo.placed_at AS placed_at,
    abo.discount_amount AS discount_amount,
    abo.discount_currency_code AS discount_currency_code,
    CASE
      WHEN osp.older_sub_id IS NULL THEN 'order preceded customer''s first-ever subscription'
      WHEN osp.older_ended_at < abo.placed_at THEN 'order fell between two subscription stints (an older subscription record exists with started_at <= order date)'
      ELSE 'unexplained - active subscription dates should already have overlapped'
    END AS category
  FROM active_bucket_orders abo
  LEFT JOIN older_sub_pick osp ON osp.order_id = abo.order_id
),
with_eur AS (
  SELECT
    c.order_id AS order_id, c.tenant_id AS tenant_id, c.user_id AS user_id, c.category AS category,
    CAST({{divide_decimal(c.discount_amount, er.rate)}} AS NUMERIC(18,6)) AS discount_amount_eur
  FROM classified c
  JOIN exchange_rates er
    ON er.base_code = 'EUR'
   AND er.quote_code = c.discount_currency_code
   AND er.as_of = CAST(c.placed_at AS DATE)
),
total AS (
  SELECT COUNT(*) AS total_orders FROM active_bucket_orders
)
SELECT
  w.category AS category,
  COUNT(*) AS order_count,
  {{divide_decimal(100.0 * COUNT(*), t.total_orders)}} AS pct_of_291_bucket,
  COUNT(DISTINCT w.user_id) AS distinct_customers,
  SUM(w.discount_amount_eur) AS total_discount_eur
FROM with_eur w
CROSS JOIN total t
GROUP BY w.category, t.total_orders
ORDER BY order_count DESC NULLS FIRST, w.category NULLS LAST
