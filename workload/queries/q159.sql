WITH discount_orders AS (
  SELECT od.discount_id AS discount_id, d.name AS discount_name, o.id AS order_id, o.grand_total AS grand_total, o.currency_code AS currency_code
  FROM order_discounts od
  JOIN discounts d ON d.id = od.discount_id
  JOIN orders o ON o.id = od.order_id
  WHERE d.name IN ('Welcome 10% off', 'Volume tier 10+')
    AND o.status <> 'cancelled'
    AND o.placed_at >= DATE '2025-01-01'
    AND o.placed_at < DATE '2026-01-01'
),
discount_counts AS (
  SELECT discount_id, discount_name, COUNT(*) AS order_count
  FROM discount_orders
  GROUP BY discount_id, discount_name
),
target_discounts AS (
  SELECT discount_id, discount_name, order_count
  FROM discount_counts
  WHERE (discount_name = 'Welcome 10% off' AND order_count = 260)
     OR (discount_name = 'Volume tier 10+' AND order_count = 104)
),
target_orders AS (
  SELECT do2.discount_id AS discount_id, td.discount_name AS discount_name, td.order_count AS order_count, do2.order_id AS order_id, do2.grand_total AS grand_total, do2.currency_code AS currency_code
  FROM discount_orders do2
  JOIN target_discounts td ON td.discount_id = do2.discount_id
),
refunds AS (
  SELECT
    tord.discount_id AS discount_id,
    tord.discount_name AS discount_name,
    tord.order_count AS order_count,
    tord.order_id AS order_id,
    tord.grand_total AS grand_total,
    orr.id AS return_id,
    orr.refund_total AS refund_total,
    orr.refunded_at AS refunded_at,
    (CAST({{divide_decimal(orr.refund_total, er.rate)}} AS NUMERIC(18,6))) AS refund_eur
  FROM target_orders tord
  JOIN order_returns orr ON orr.order_id = tord.order_id AND orr.status = 'refunded'
  JOIN exchange_rates er ON er.base_code = 'EUR'
    AND er.quote_code = orr.currency_code
    AND er.as_of = CAST(orr.refunded_at AS date)
),
order_refund_totals AS (
  SELECT discount_id, discount_name, order_id, grand_total, SUM(refund_total) AS total_refund_native
  FROM refunds
  GROUP BY discount_id, discount_name, order_id, grand_total
),
ranked_refunds AS (
  SELECT
    discount_id,
    discount_name,
    refund_eur,
    ROW_NUMBER() OVER (PARTITION BY discount_id ORDER BY refund_eur DESC NULLS FIRST) AS rn
  FROM refunds
),
discount_agg AS (
  SELECT
    discount_id,
    discount_name,
    COUNT(*) AS refund_count,
    SUM(refund_eur) AS total_refund_eur,
    MAX(refund_eur) AS max_refund_eur,
    {{percentile_cont(0.5, refund_eur)}} AS median_refund_eur
  FROM refunds
  GROUP BY discount_id, discount_name
),
top3_agg AS (
  SELECT discount_id, SUM(refund_eur) AS top3_sum
  FROM ranked_refunds
  WHERE rn <= 3
  GROUP BY discount_id
),
full_refund_agg AS (
  SELECT discount_id, COUNT(*) AS full_refund_orders
  FROM order_refund_totals
  WHERE total_refund_native >= grand_total
  GROUP BY discount_id
)
SELECT
  td.discount_name AS discount_name,
  td.order_count AS order_count,
  da.total_refund_eur AS total_refunded_eur,
  da.refund_count AS refund_count,
  {{divide_decimal(100.0 * t3.top3_sum, NULLIF(da.total_refund_eur,0))}} AS top3_pct_of_total,
  da.median_refund_eur AS median_refund_eur,
  da.max_refund_eur AS max_refund_eur,
  {{divide_decimal(100.0 * COALESCE(fr.full_refund_orders,0), td.order_count)}} AS pct_orders_fully_refunded
FROM target_discounts td
JOIN discount_agg da ON da.discount_id = td.discount_id
LEFT JOIN top3_agg t3 ON t3.discount_id = td.discount_id
LEFT JOIN full_refund_agg fr ON fr.discount_id = td.discount_id
ORDER BY td.discount_name ASC NULLS LAST, td.discount_id NULLS LAST
