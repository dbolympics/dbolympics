SELECT
  ra.referrer_user_id AS referrer_user_id,
  t.name AS tenant_name,
  ra.redemption_count AS redemption_count,
  ra.distinct_referred_customers AS distinct_referred_customers,
  ra.total_reward_paid_eur AS total_reward_paid_eur,
  {{divide_decimal(100.0 * ra.redemption_count, SUM(ra.redemption_count) OVER ())}} AS share_of_all_redemptions_pct,
  COALESCE(oa.lifetime_order_count, 0) AS referrer_lifetime_order_count,
  COALESCE(oa.lifetime_revenue_eur, 0) AS referrer_lifetime_revenue_eur
FROM (
    SELECT rr.tenant_id AS tenant_id, ref.referrer_user_id AS referrer_user_id,
           COUNT(*) AS redemption_count,
           COUNT(DISTINCT rr.referred_user_id) AS distinct_referred_customers,
           SUM(CASE WHEN rr.currency_code = 'EUR' THEN rr.reward_amount
                    ELSE CAST({{divide_decimal(rr.reward_amount, er.rate)}} AS NUMERIC(18,6)) END) AS total_reward_paid_eur
    FROM referral_redemptions rr
    JOIN referrals ref ON ref.id = rr.referral_id
    LEFT JOIN exchange_rates er
      ON er.base_code = 'EUR'
     AND er.quote_code = rr.currency_code
     AND er.as_of = CAST(rr.redeemed_at AS date)
    GROUP BY rr.tenant_id, ref.referrer_user_id
) ra
JOIN tenants t ON t.id = ra.tenant_id
LEFT JOIN (
    SELECT o.tenant_id AS tenant_id, o.user_id AS user_id,
           COUNT(*) AS lifetime_order_count,
           SUM(CASE WHEN o.status <> 'cancelled' THEN
                    CASE WHEN o.currency_code = 'EUR' THEN o.grand_total
                         ELSE CAST({{divide_decimal(o.grand_total, er.rate)}} AS NUMERIC(18,6)) END
                    ELSE 0 END) AS lifetime_revenue_eur
    FROM orders o
    LEFT JOIN exchange_rates er
      ON er.base_code = 'EUR'
     AND er.quote_code = o.currency_code
     AND er.as_of = CAST(o.placed_at AS date)
    GROUP BY o.tenant_id, o.user_id
) oa ON oa.tenant_id = ra.tenant_id AND oa.user_id = ra.referrer_user_id
ORDER BY ra.redemption_count DESC NULLS FIRST, ra.referrer_user_id ASC NULLS LAST, ra.tenant_id NULLS LAST
{{fetch_first(50)}}
