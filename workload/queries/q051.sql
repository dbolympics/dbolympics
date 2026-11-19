WITH months AS (
  SELECT DISTINCT month_label AS month
  FROM calendar_days
  WHERE year_num = 2025
),
order_calc AS (
  SELECT
    {{year_month(o.placed_at)}} AS month,
    {{divide_decimal(o.grand_total, CASE WHEN o.currency_code = 'EUR' THEN 1 ELSE er.rate END)}} AS revenue_eur,
    {{divide_decimal(o.discount_total, CASE WHEN o.currency_code = 'EUR' THEN 1 ELSE er.rate END)}} AS discount_eur,
    CASE WHEN o.discount_total > 0 THEN 1 ELSE 0 END AS has_discount
  FROM orders o
  LEFT JOIN exchange_rates er
    ON er.base_code = 'EUR'
    AND er.quote_code = o.currency_code
    AND er.as_of = CAST(o.placed_at AS DATE)
  WHERE o.placed_at >= DATE '2025-01-01'
    AND o.placed_at < DATE '2026-01-01'
    AND o.status <> 'cancelled'
),
order_agg AS (
  SELECT
    month,
    COUNT(*) AS orders_count,
    SUM(has_discount) AS orders_with_discount_count,
    SUM(revenue_eur) AS total_order_revenue_eur,
    SUM(discount_eur) AS total_discount_amount_eur
  FROM order_calc
  GROUP BY month
),
coupon_agg AS (
  SELECT
    {{year_month(cr.redeemed_at)}} AS month,
    COUNT(DISTINCT cr.coupon_id) AS distinct_coupons_used
  FROM coupon_redemptions cr
  WHERE cr.redeemed_at >= DATE '2025-01-01'
    AND cr.redeemed_at < DATE '2026-01-01'
  GROUP BY month
)
SELECT
  m.month AS month,
  COALESCE(oa.orders_count, 0) AS orders_count,
  COALESCE(oa.orders_with_discount_count, 0) AS orders_with_discount_count,
  {{divide_decimal(CAST(COALESCE(oa.orders_with_discount_count, 0) AS numeric(18,6)) * 100.0, NULLIF(oa.orders_count,0))}} AS discount_rate_pct,
  COALESCE(oa.total_order_revenue_eur,0) AS total_order_revenue_eur,
  COALESCE(oa.total_discount_amount_eur,0) AS total_discount_amount_eur,
  COALESCE(oa.total_discount_amount_eur,0) * 100.0 / NULLIF(oa.total_order_revenue_eur + oa.total_discount_amount_eur, 0) AS discount_share_of_gmv_pct,
  COALESCE(ca.distinct_coupons_used, 0) AS distinct_coupons_used,
  COALESCE(oa.total_discount_amount_eur,0) / NULLIF(oa.orders_with_discount_count,0) AS avg_discount_per_discounted_order_eur
FROM months m
LEFT JOIN order_agg oa ON oa.month = m.month
LEFT JOIN coupon_agg ca ON ca.month = m.month
ORDER BY m.month NULLS LAST
