WITH t0 AS (
  SELECT
    o0.id AS order_id,
    o0.status AS order_status,
    CAST({{divide_decimal(o0.grand_total, er0.rate)}} AS NUMERIC(18,6)) AS grand_total_eur
  FROM orders o0
  JOIN exchange_rates er0
    ON er0.base_code = 'EUR'
   AND er0.quote_code = o0.currency_code
   AND er0.as_of = CAST(o0.placed_at AS date)
  WHERE o0.placed_at >= TIMESTAMP '2023-01-01 00:00:00'
    AND o0.placed_at < TIMESTAMP '2025-07-01 00:00:00'
),
t1 AS (
  SELECT
    p1.order_id AS order_id,
    CAST({{divide_decimal(p1.amount, er1.rate)}} AS NUMERIC(18,6)) AS gross_eur,
    CAST({{divide_decimal((p1.amount - p1.amount_refunded), er1.rate)}} AS NUMERIC(18,6)) AS net_eur
  FROM payments p1
  JOIN exchange_rates er1
    ON er1.base_code = 'EUR'
   AND er1.quote_code = p1.currency_code
   AND er1.as_of = CAST(p1.captured_at AS date)
  WHERE p1.status IN ('captured', 'refunded', 'partially_refunded')
    AND p1.order_id IN (SELECT t0.order_id AS order_id FROM t0)
),
t2 AS (
  SELECT
    t1.order_id AS order_id,
    SUM(t1.gross_eur) AS gross_eur,
    SUM(t1.net_eur) AS net_eur
  FROM t1
  GROUP BY t1.order_id
),
t3 AS (
  SELECT
    t0.order_status AS order_status,
    COUNT(t0.order_id) AS order_count,
    SUM(t0.grand_total_eur) AS orders_grand_total_eur
  FROM t0
  GROUP BY t0.order_status
),
t4 AS (
  SELECT
    t0.order_status AS order_status,
    COUNT(t2.order_id) AS orders_with_money_collected_count,
    SUM(COALESCE(t2.gross_eur, 0)) AS gross_collected_eur,
    SUM(COALESCE(t2.net_eur, 0)) AS net_collected_eur
  FROM t0
  LEFT JOIN t2
    ON t2.order_id = t0.order_id
  GROUP BY t0.order_status
)
SELECT
  t3.order_status AS order_status,
  t3.order_count AS order_count,
  t3.orders_grand_total_eur AS orders_grand_total_eur,
  t4.orders_with_money_collected_count AS orders_with_money_collected_count,
  t4.gross_collected_eur AS gross_collected_eur,
  t4.net_collected_eur AS net_collected_eur,
  t3.orders_grand_total_eur - t4.gross_collected_eur AS gap_vs_gross_eur,
  {{divide_decimal((t3.orders_grand_total_eur - t4.gross_collected_eur), NULLIF(t3.orders_grand_total_eur, 0))}} * 100 AS gap_vs_gross_pct
FROM t3
JOIN t4
  ON t4.order_status = t3.order_status
ORDER BY t3.orders_grand_total_eur DESC NULLS FIRST, t3.order_status ASC NULLS LAST
