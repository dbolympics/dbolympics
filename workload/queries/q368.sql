WITH order_sub AS (
  SELECT
    o.id AS order_id,
    o.tenant_id AS tenant_id,
    o.user_id AS user_id,
    o.discount_total AS discount_total,
    o.currency_code AS currency_code,
    o.placed_at AS placed_at,
    (
      SELECT s.status
      FROM invoices i
      JOIN subscriptions s ON s.id = i.subscription_id
      WHERE i.order_id = o.id
      ORDER BY i.issued_at DESC NULLS LAST, i.id DESC NULLS FIRST
      {{fetch_first(1)}}
    ) AS subscription_status
  FROM orders o
  WHERE o.placed_at >= DATE '2023-01-01'
    AND o.placed_at < DATE '2026-01-01'
    AND o.status <> 'cancelled'
    AND o.discount_total > 0
    AND NOT EXISTS (
      SELECT 1 FROM order_discounts od WHERE od.order_id = o.id
    )
),
rated AS (
  SELECT
    os.tenant_id AS tenant_id,
    os.user_id AS user_id,
    os.order_id AS order_id,
    CASE
      WHEN os.subscription_status = 'canceled' THEN 'canceled'
      WHEN os.subscription_status = 'active' THEN 'active'
      ELSE 'other-or-no-subscription-record'
    END AS status_category,
    CASE
      WHEN os.currency_code = 'EUR' THEN os.discount_total
      ELSE CAST({{divide_decimal(os.discount_total, er.rate)}} AS NUMERIC(18,6))
    END AS discount_eur
  FROM order_sub os
  LEFT JOIN exchange_rates er
    ON er.base_code = 'EUR'
    AND er.quote_code = os.currency_code
    AND er.as_of = CAST(os.placed_at AS date)
)
SELECT
  t.name AS tenant_name,
  r.status_category AS status_category,
  COUNT(*) AS orphan_order_count,
  COUNT(DISTINCT r.user_id) AS distinct_customers,
  SUM(r.discount_eur) AS total_discount_eur
FROM rated r
JOIN tenants t ON t.id = r.tenant_id
GROUP BY t.name, r.status_category
ORDER BY t.name NULLS LAST, r.status_category NULLS LAST
