WITH discount_eur AS (
  SELECT od.discount_id AS discount_id,
         SUM(CAST({{divide_decimal(od.amount, er.rate)}} AS NUMERIC(18,6))) AS discount_amount_eur
  FROM order_discounts od
  JOIN orders o ON o.id = od.order_id
  JOIN discounts d ON d.id = od.discount_id
  JOIN exchange_rates er
    ON er.base_code = 'EUR'
   AND er.quote_code = od.currency_code
   AND er.as_of = CAST(o.placed_at AS date)
  WHERE o.placed_at >= DATE '2025-01-01'
    AND o.placed_at <  DATE '2026-01-01'
    AND o.status <> 'cancelled'
    AND d.name <> 'Subscription delivery'
  GROUP BY od.discount_id
),
top15 AS (
  SELECT discount_id, discount_amount_eur,
         ROW_NUMBER() OVER (ORDER BY discount_amount_eur DESC NULLS FIRST, discount_id ASC NULLS LAST) AS rn
  FROM discount_eur
),
discounted_orders AS (
  SELECT DISTINCT od.discount_id AS discount_id, o.id AS order_id, o.tenant_id AS tenant_id
  FROM order_discounts od
  JOIN orders o ON o.id = od.order_id
  WHERE od.discount_id IN (SELECT discount_id FROM top15 WHERE rn <= 15)
    AND o.status <> 'cancelled'
    AND o.placed_at >= DATE '2025-01-01'
    AND o.placed_at <  DATE '2026-01-01'
),
order_rma_flag AS (
  SELECT dco.discount_id AS discount_id, dco.order_id AS order_id,
         EXISTS (SELECT 1 FROM order_returns orr WHERE orr.order_id = dco.order_id) AS has_rma
  FROM discounted_orders dco
),
discount_summary AS (
  SELECT dco.discount_id AS discount_id,
         COUNT(DISTINCT dco.order_id) AS order_count,
         COUNT(DISTINCT dco.order_id) FILTER (WHERE f.has_rma) AS orders_with_rma
  FROM discounted_orders dco
  JOIN order_rma_flag f ON f.discount_id = dco.discount_id AND f.order_id = dco.order_id
  GROUP BY dco.discount_id
),
refunds AS (
  SELECT dco.discount_id AS discount_id,
         SUM(CAST({{divide_decimal(orr.refund_total, er.rate)}} AS NUMERIC(18,6))) AS refund_eur
  FROM discounted_orders dco
  JOIN order_returns orr ON orr.order_id = dco.order_id AND orr.status = 'refunded'
  JOIN orders o ON o.id = dco.order_id
  JOIN exchange_rates er
    ON er.base_code = 'EUR'
   AND er.quote_code = orr.currency_code
   AND er.as_of = CAST(COALESCE(orr.refunded_at, o.placed_at) AS date)
  GROUP BY dco.discount_id
),
baseline AS (
  SELECT o.tenant_id AS tenant_id,
         COUNT(DISTINCT o.id) AS baseline_order_count,
         COUNT(DISTINCT o.id) FILTER (
           WHERE EXISTS (SELECT 1 FROM order_returns orr2 WHERE orr2.order_id = o.id)
         ) AS baseline_rma_count
  FROM orders o
  WHERE o.status <> 'cancelled'
    AND o.placed_at >= DATE '2025-01-01'
    AND o.placed_at <  DATE '2026-01-01'
    AND NOT EXISTS (SELECT 1 FROM order_discounts od2 WHERE od2.order_id = o.id)
  GROUP BY o.tenant_id
)
SELECT
  d.name AS discount_name,
  COALESCE(cc.code, 'automatic') AS coupon_code,
  ds.order_count AS order_count,
  ds.orders_with_rma AS orders_with_rma,
  {{divide_decimal(100.0 * ds.orders_with_rma, NULLIF(ds.order_count, 0))}} AS return_rate_pct,
  COALESCE(r.refund_eur, 0) AS total_refunded_eur,
  {{divide_decimal(100.0 * COALESCE(r.refund_eur, 0), NULLIF(t.discount_amount_eur, 0))}} AS refund_pct_of_discount_cost,
  {{divide_decimal(100.0 * b.baseline_rma_count, NULLIF(b.baseline_order_count, 0))}} AS baseline_return_rate_pct,
  {{divide_decimal(100.0 * ds.orders_with_rma, NULLIF(ds.order_count, 0))}}
  - {{divide_decimal(100.0 * b.baseline_rma_count, NULLIF(b.baseline_order_count, 0))}} AS return_rate_lift_pp
FROM top15 t
JOIN discounts d ON d.id = t.discount_id
JOIN discount_summary ds ON ds.discount_id = t.discount_id
LEFT JOIN refunds r ON r.discount_id = t.discount_id
LEFT JOIN baseline b ON b.tenant_id = d.tenant_id
LEFT JOIN LATERAL (
  SELECT c.code AS code FROM coupons c WHERE c.discount_id = d.id ORDER BY c.id NULLS LAST {{fetch_first(1)}}
) cc ON true
WHERE t.rn <= 15
ORDER BY return_rate_lift_pp DESC NULLS LAST, discount_name ASC NULLS LAST, t.discount_id ASC NULLS LAST
