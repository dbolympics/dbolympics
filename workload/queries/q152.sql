WITH redemptions AS (
  SELECT
    cr.coupon_id AS coupon_id,
    cr.user_id AS user_id,
    cr.discount_amount AS discount_amount,
    cr.currency_code AS currency_code,
    cr.redeemed_at AS redeemed_at
  FROM coupon_redemptions cr
  WHERE cr.redeemed_at >= DATE '2023-01-01'
    AND cr.redeemed_at < DATE '2026-01-01'
),
coupon_stats AS (
  SELECT
    r.coupon_id AS coupon_id,
    COUNT(*) AS times_redeemed,
    COUNT(DISTINCT r.user_id) AS distinct_customers,
    SUM(CAST({{divide_decimal(r.discount_amount, COALESCE(er.rate, 1))}} AS NUMERIC(18,6))) AS total_discount_eur
  FROM redemptions r
  LEFT JOIN exchange_rates er
    ON er.base_code = 'EUR'
   AND er.quote_code = r.currency_code
   AND er.as_of = CAST(r.redeemed_at AS date)
  GROUP BY r.coupon_id
),
per_customer AS (
  SELECT
    r.coupon_id AS coupon_id,
    r.user_id AS user_id,
    COUNT(*) AS redemption_count
  FROM redemptions r
  GROUP BY r.coupon_id, r.user_id
),
customer_stats AS (
  SELECT
    pc.coupon_id AS coupon_id,
    MAX(pc.redemption_count) AS max_redemptions_by_customer,
    COUNT(*) FILTER (WHERE c.per_customer_limit IS NOT NULL AND pc.redemption_count > c.per_customer_limit) AS customers_exceeding
  FROM per_customer pc
  JOIN coupons c ON c.id = pc.coupon_id
  GROUP BY pc.coupon_id
)
SELECT
  c.code AS coupon_code,
  t.name AS tenant_name,
  c.status AS status,
  c.usage_limit AS usage_limit,
  c.per_customer_limit AS per_customer_limit,
  COALESCE(cs.times_redeemed, 0) AS times_redeemed,
  CASE WHEN c.usage_limit IS NOT NULL
       THEN GREATEST(COALESCE(cs.times_redeemed, 0) - c.usage_limit, 0)
       ELSE 0 END AS redemptions_over_usage_limit,
  COALESCE(custs.max_redemptions_by_customer, 0) AS max_redemptions_by_customer,
  COALESCE(custs.customers_exceeding, 0) AS customers_exceeding_per_customer_limit,
  COALESCE(cs.total_discount_eur, 0) AS total_discount_redeemed_eur,
  COUNT(*) OVER () AS total_matching_coupons
FROM coupons c
JOIN tenants t ON t.id = c.tenant_id
LEFT JOIN coupon_stats cs ON cs.coupon_id = c.id
LEFT JOIN customer_stats custs ON custs.coupon_id = c.id
WHERE (c.usage_limit IS NOT NULL OR c.per_customer_limit IS NOT NULL)
  AND (
    (c.usage_limit IS NOT NULL AND COALESCE(cs.times_redeemed, 0) > c.usage_limit)
    OR COALESCE(custs.customers_exceeding, 0) > 0
  )
ORDER BY redemptions_over_usage_limit DESC NULLS FIRST, customers_exceeding_per_customer_limit DESC NULLS FIRST, coupon_code ASC NULLS LAST, c.id ASC NULLS LAST
{{fetch_first(50)}}
