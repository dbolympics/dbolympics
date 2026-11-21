WITH redemptions AS (
  SELECT
    cr.coupon_id AS coupon_id,
    cr.user_id AS user_id,
    cr.discount_amount AS discount_amount,
    cr.currency_code AS currency_code,
    cr.redeemed_at AS redeemed_at,
    c.code AS coupon_code,
    c.status AS status,
    c.usage_limit AS usage_limit,
    c.per_customer_limit AS per_customer_limit,
    c.starts_at AS starts_at,
    c.expires_at AS expires_at,
    CAST({{divide_decimal(cr.discount_amount, NULLIF(er.rate, 0))}} AS NUMERIC(18,6)) AS discount_amount_eur
  FROM coupon_redemptions cr
  JOIN coupons c ON cr.coupon_id = c.id
  LEFT JOIN exchange_rates er
    ON er.base_code = 'EUR'
    AND er.quote_code = cr.currency_code
    AND er.as_of = CAST(cr.redeemed_at AS date)
  WHERE cr.redeemed_at >= DATE '2023-01-01'
    AND cr.redeemed_at < DATE '2026-01-01'
),
per_customer AS (
  SELECT coupon_id, user_id, COUNT(*) AS redemption_count
  FROM redemptions
  GROUP BY coupon_id, user_id
),
customer_max AS (
  SELECT coupon_id, MAX(redemption_count) AS max_redemptions_by_customer
  FROM per_customer
  GROUP BY coupon_id
)
SELECT
  r.coupon_code AS coupon_code,
  MAX(r.status) AS status,
  MAX(r.usage_limit) AS usage_limit,
  MAX(r.per_customer_limit) AS per_customer_limit,
  COUNT(*) AS times_redeemed,
  COUNT(DISTINCT r.user_id) AS distinct_customers,
  cm.max_redemptions_by_customer AS max_redemptions_by_customer,
  COUNT(*) FILTER (WHERE r.redeemed_at > r.expires_at) AS redemptions_after_expiry,
  COUNT(*) FILTER (WHERE r.redeemed_at < r.starts_at) AS redemptions_before_start,
  SUM(r.discount_amount_eur) AS total_discount_eur
FROM redemptions r
JOIN customer_max cm ON cm.coupon_id = r.coupon_id
GROUP BY r.coupon_id, r.coupon_code, cm.max_redemptions_by_customer
ORDER BY redemptions_after_expiry DESC NULLS FIRST, max_redemptions_by_customer DESC NULLS FIRST, coupon_code ASC NULLS LAST, r.coupon_id NULLS LAST
{{fetch_first(50)}}
