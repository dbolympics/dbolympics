WITH quarters AS (
  SELECT
    quarter_start,
    MAX(calendar_date) AS quarter_end,
    year_num,
    quarter_num
  FROM calendar_days
  WHERE quarter_start BETWEEN DATE '2024-01-01' AND DATE '2025-12-31'
  GROUP BY quarter_start, year_num, quarter_num
),
new_merchants AS (
  SELECT
    q.quarter_start AS quarter_start,
    COUNT(t.id) AS new_merchant_count
  FROM quarters q
  LEFT JOIN tenants t
    ON t.created_at >= q.quarter_start
   AND t.created_at < q.quarter_end + INTERVAL '1 day'
  GROUP BY q.quarter_start
),
cumulative_merchants AS (
  SELECT
    q.quarter_start AS quarter_start,
    COUNT(t.id) AS cumulative_active_merchants
  FROM quarters q
  LEFT JOIN tenants t
    ON t.created_at < q.quarter_end + INTERVAL '1 day'
   AND t.deleted_at IS NULL
  GROUP BY q.quarter_start
),
order_amounts_eur AS (
  SELECT
    o.id AS id,
    o.placed_at AS placed_at,
    CAST({{divide_decimal(o.grand_total, er.rate)}} AS NUMERIC(18,6)) AS amount_eur
  FROM orders o
  JOIN exchange_rates er
    ON er.base_code = 'EUR'
   AND er.quote_code = o.currency_code
   AND er.as_of = CAST(o.placed_at AS DATE)
  WHERE o.status IN ('paid','partially_fulfilled','fulfilled','refunded')
    AND o.placed_at >= DATE '2024-01-01'
    AND o.placed_at < DATE '2026-01-01'
),
orders_in_quarter AS (
  SELECT
    q.quarter_start AS quarter_start,
    COUNT(oa.id) AS order_count,
    SUM(oa.amount_eur) AS gmv_eur
  FROM quarters q
  LEFT JOIN order_amounts_eur oa
    ON oa.placed_at >= q.quarter_start
   AND oa.placed_at < q.quarter_end + INTERVAL '1 day'
  GROUP BY q.quarter_start
)
SELECT
  q.year_num || '-Q' || q.quarter_num AS quarter,
  nm.new_merchant_count AS new_merchants,
  cm.cumulative_active_merchants AS cumulative_active_merchants,
  oiq.order_count AS order_count,
  oiq.gmv_eur AS gmv_eur,
  {{divide_decimal(oiq.gmv_eur, NULLIF(oiq.order_count, 0))}} AS avg_order_value_eur
FROM quarters q
JOIN new_merchants nm ON nm.quarter_start = q.quarter_start
JOIN cumulative_merchants cm ON cm.quarter_start = q.quarter_start
JOIN orders_in_quarter oiq ON oiq.quarter_start = q.quarter_start
ORDER BY q.quarter_start ASC NULLS LAST, q.year_num NULLS LAST, q.quarter_num NULLS LAST
