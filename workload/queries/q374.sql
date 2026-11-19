WITH apparel_orders AS (
  SELECT o.id AS id, o.tenant_id AS tenant_id, o.user_id AS user_id, o.currency_code AS currency_code, o.subtotal AS subtotal, o.discount_total AS discount_total, o.grand_total AS grand_total, o.placed_at AS placed_at
  FROM orders o
  JOIN tenants t ON t.id = o.tenant_id
  JOIN users u ON u.id = o.user_id
  WHERE t.industry = 'Apparel & Footwear'
    AND u.is_staff = false
    AND o.status <> 'cancelled'
    AND o.placed_at >= DATE '2023-01-01'
    AND o.placed_at < DATE '2026-01-01'
),
user_segment AS (
  SELECT ao.*,
    CASE WHEN la.user_id IS NOT NULL THEN 'loyalty member' ELSE 'non-member' END AS segment
  FROM apparel_orders ao
  LEFT JOIN (SELECT DISTINCT user_id FROM loyalty_accounts) la ON la.user_id = ao.user_id
),
fx_converted AS (
  SELECT us.segment AS segment,
    {{divide_decimal(us.subtotal, CASE WHEN us.currency_code = 'EUR' THEN 1 ELSE er.rate END)}} AS subtotal_eur,
    {{divide_decimal(us.discount_total, CASE WHEN us.currency_code = 'EUR' THEN 1 ELSE er.rate END)}} AS discount_total_eur,
    {{divide_decimal(us.grand_total, CASE WHEN us.currency_code = 'EUR' THEN 1 ELSE er.rate END)}} AS grand_total_eur
  FROM user_segment us
  LEFT JOIN exchange_rates er ON er.base_code = 'EUR' AND er.quote_code = us.currency_code AND er.as_of = CAST(us.placed_at AS DATE)
),
segment_agg AS (
  SELECT segment,
    COUNT(*) AS order_count,
    AVG(subtotal_eur) AS avg_subtotal_eur,
    AVG(discount_total_eur) AS avg_discount_total_eur,
    AVG(grand_total_eur) AS avg_grand_total_eur,
    SUM(discount_total_eur) AS sum_discount_eur,
    SUM(subtotal_eur) AS sum_subtotal_eur
  FROM fx_converted
  GROUP BY segment
)
SELECT
  segment,
  order_count,
  avg_subtotal_eur AS avg_subtotal_eur,
  avg_discount_total_eur AS avg_discount_total_eur,
  avg_grand_total_eur AS avg_grand_total_eur,
  100.0 * sum_discount_eur / NULLIF(sum_subtotal_eur,0) AS discount_rate_pct
FROM segment_agg
ORDER BY CASE WHEN segment = 'loyalty member' THEN 0 ELSE 1 END NULLS LAST, segment NULLS LAST
