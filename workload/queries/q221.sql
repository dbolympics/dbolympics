WITH base AS (
  SELECT t0.id AS return_id, t0.order_id AS order_id, t0.refund_total AS refund_total, t0.currency_code AS currency_code, t0.refunded_at AS refunded_at
  FROM order_returns t0
  WHERE t0.status = 'refunded'
    AND t0.refunded_at >= DATE '2025-01-01'
    AND t0.refunded_at < DATE '2026-01-01'
),
first_payment AS (
  SELECT t1.order_id AS order_id, MIN(t1.captured_at) AS first_captured_at
  FROM payments t1
  WHERE t1.captured_at IS NOT NULL
  GROUP BY t1.order_id
),
joined AS (
  SELECT
    b.return_id AS return_id,
    b.refund_total AS refund_total,
    b.currency_code AS currency_code,
    b.refunded_at AS refunded_at,
    o.id AS order_id,
    fp.first_captured_at AS first_captured_at
  FROM base b
  LEFT JOIN orders o ON o.id = b.order_id
  LEFT JOIN first_payment fp ON fp.order_id = o.id
),
rated AS (
  SELECT
    j.*,
    CASE WHEN j.currency_code = 'EUR' THEN 1.0
         ELSE er.rate END AS fx_rate
  FROM joined j
  LEFT JOIN exchange_rates er
    ON er.base_code = 'EUR'
   AND er.quote_code = j.currency_code
   AND er.as_of = CAST(j.refunded_at AS date)
),
categorized AS (
  SELECT
    r.*,
    CASE WHEN r.fx_rate IS NULL OR r.fx_rate = 0 THEN NULL ELSE CAST({{divide_decimal(r.refund_total, r.fx_rate)}} AS NUMERIC(18,6)) END AS refund_amount_eur,
    CASE WHEN r.first_captured_at IS NULL THEN NULL
         ELSE (EXTRACT(YEAR FROM r.refunded_at)*4 + EXTRACT(QUARTER FROM r.refunded_at))
            - (EXTRACT(YEAR FROM r.first_captured_at)*4 + EXTRACT(QUARTER FROM r.first_captured_at))
    END AS quarter_diff,
    CASE WHEN r.first_captured_at IS NULL THEN NULL
         ELSE {{divide_decimal({{seconds_between(r.first_captured_at, r.refunded_at)}}, 86400.0)}}
    END AS lag_days
  FROM rated r
),
bucketed AS (
  SELECT
    c.*,
    CASE
      WHEN c.quarter_diff IS NULL THEN 'no matching payment found'
      WHEN c.quarter_diff <= 0 THEN 'same quarter as purchase'
      WHEN c.quarter_diff = 1 THEN 'purchase 1 quarter earlier'
      ELSE 'purchase 2+ quarters earlier'
    END AS lag_category
  FROM categorized c
)
SELECT
  b.lag_category AS lag_category,
  COUNT(*) AS return_count,
  SUM(b.refund_amount_eur) AS refund_amount_eur,
  {{divide_decimal(100.0 * SUM(b.refund_amount_eur), SUM(SUM(b.refund_amount_eur)) OVER ())}} AS pct_of_total_2025_refund_amount,
  AVG(b.lag_days) AS avg_lag_days
FROM bucketed b
GROUP BY b.lag_category
ORDER BY return_count DESC NULLS FIRST, b.lag_category ASC NULLS LAST
