WITH base_orders AS (
  SELECT
    o.id AS order_id,
    o.tenant_id AS tenant_id,
    o.user_id AS user_id,
    o.placed_at AS placed_at,
    o.currency_code AS currency_code
  FROM orders o
  WHERE o.placed_at >= DATE '2025-01-01'
    AND o.placed_at < DATE '2026-01-01'
    AND o.status != 'cancelled'
    AND EXISTS (
      SELECT 1
      FROM order_discounts od
      JOIN discounts d ON d.id = od.discount_id
      WHERE od.order_id = o.id
        AND d.name = 'Subscription delivery (prepaid)'
    )
),
row_per_order AS (
  SELECT
    bo.order_id AS order_id,
    bo.tenant_id AS tenant_id,
    bo.user_id AS user_id,
    bo.placed_at AS placed_at,
    bo.currency_code AS currency_code,
    (
      SELECT SUM(od.amount)
      FROM order_discounts od
      JOIN discounts d ON d.id = od.discount_id
      WHERE od.order_id = bo.order_id
        AND d.name = 'Subscription delivery (prepaid)'
    ) AS discount_amount,
    NOT EXISTS (
      SELECT 1
      FROM subscriptions s
      WHERE s.tenant_id = bo.tenant_id
        AND s.user_id = bo.user_id
        AND s.status IN ('trialing', 'active', 'past_due')
        AND s.started_at <= bo.placed_at
        AND (s.ended_at IS NULL OR s.ended_at >= bo.placed_at)
    ) AS is_orphan,
    (
      SELECT s2.status
      FROM subscriptions s2
      WHERE s2.tenant_id = bo.tenant_id
        AND s2.user_id = bo.user_id
      ORDER BY s2.started_at DESC NULLS FIRST, s2.id DESC NULLS FIRST
      {{fetch_first(1)}}
    ) AS most_recent_status,
    (
      SELECT er.rate
      FROM exchange_rates er
      WHERE er.base_code = 'EUR'
        AND er.quote_code = bo.currency_code
        AND er.as_of = CAST(bo.placed_at AS DATE)
    ) AS fx_rate
  FROM base_orders bo
),
categorized AS (
  SELECT
    r.*,
    CASE
      WHEN r.most_recent_status = 'canceled' THEN 'canceled'
      WHEN r.most_recent_status = 'active' THEN 'active'
      ELSE 'other-or-no-subscription-record'
    END AS status_category,
    CASE
      WHEN r.currency_code = 'EUR' THEN r.discount_amount
      ELSE CAST({{divide_decimal(r.discount_amount, NULLIF(r.fx_rate, 0))}} AS NUMERIC(18,6))
    END AS eur_amount
  FROM row_per_order r
)
SELECT
  t.name AS tenant_name,
  c.status_category AS status_category,
  COUNT(*) AS orphan_order_count,
  COUNT(DISTINCT c.user_id) AS distinct_customers,
  SUM(c.eur_amount) AS total_discount_amount_eur
FROM categorized c
JOIN tenants t ON t.id = c.tenant_id
WHERE c.is_orphan
GROUP BY t.name, c.status_category
ORDER BY t.name NULLS LAST, c.status_category NULLS LAST
