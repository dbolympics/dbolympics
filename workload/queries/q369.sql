WITH orphan_orders AS (
  SELECT o.id AS order_id, o.tenant_id AS tenant_id, o.user_id AS user_id, o.placed_at AS placed_at, o.discount_total AS discount_total, o.currency_code AS currency_code
  FROM orders o
  WHERE o.placed_at >= DATE '2025-01-01' AND o.placed_at < DATE '2026-01-01'
    AND NOT EXISTS (
      SELECT 1 FROM subscriptions s
      WHERE s.tenant_id = o.tenant_id AND s.user_id = o.user_id
        AND s.started_at <= o.placed_at
        AND (s.ended_at IS NULL OR s.ended_at >= o.placed_at)
    )
),
most_recent_sub AS (
  SELECT oo.order_id AS order_id, oo.tenant_id AS tenant_id, oo.user_id AS user_id, oo.placed_at AS placed_at, oo.discount_total AS discount_total, oo.currency_code AS currency_code,
         s.id AS sub_id, s.started_at AS sub_started_at, s.ended_at AS sub_ended_at, s.status AS sub_status,
         ROW_NUMBER() OVER (PARTITION BY oo.order_id ORDER BY s.started_at DESC NULLS FIRST, s.id DESC NULLS FIRST) AS rn
  FROM orphan_orders oo
  JOIN subscriptions s ON s.tenant_id = oo.tenant_id AND s.user_id = oo.user_id
),
base AS (
  SELECT
    mrs.order_id AS order_id, mrs.tenant_id AS tenant_id, mrs.user_id AS user_id, mrs.placed_at AS placed_at, mrs.discount_total AS discount_total, mrs.currency_code AS currency_code,
    mrs.sub_started_at AS sub_started_at, mrs.sub_ended_at AS sub_ended_at, mrs.sub_status AS sub_status,
    CASE
      WHEN mrs.sub_started_at > mrs.placed_at THEN 'subscription started after this order'
      WHEN mrs.sub_started_at <= mrs.placed_at AND mrs.sub_ended_at IS NOT NULL AND mrs.sub_ended_at < mrs.placed_at THEN 'active status but already past its end date'
      ELSE 'dates indicate overlap - likely a bug in the original orphan flag'
    END AS category,
    CASE
      WHEN mrs.currency_code = 'EUR' THEN CAST(mrs.discount_total AS NUMERIC(18,6))
      ELSE CAST({{divide_decimal(mrs.discount_total, er.rate)}} AS NUMERIC(18,6))
    END AS discount_amount_eur
  FROM most_recent_sub mrs
  LEFT JOIN exchange_rates er
    ON er.base_code = 'EUR' AND er.quote_code = mrs.currency_code AND er.as_of = CAST(mrs.placed_at AS DATE)
  WHERE mrs.rn = 1 AND mrs.sub_status = 'active'
)
SELECT
  category,
  COUNT(*) AS order_count,
  {{divide_decimal(100.0 * COUNT(*), SUM(COUNT(*)) OVER ())}} AS pct_of_active_bucket,
  COUNT(DISTINCT user_id) AS distinct_customers,
  SUM(discount_amount_eur) AS total_discount_eur
FROM base
GROUP BY category
ORDER BY order_count DESC NULLS FIRST, category NULLS LAST
