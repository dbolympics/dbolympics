WITH member_enroll AS (
  SELECT la.user_id AS user_id, MIN(la.enrolled_at) AS enrolled_at
  FROM loyalty_accounts la
  GROUP BY la.user_id
),
member_first_burn AS (
  SELECT lt.user_id AS user_id, MIN(lt.occurred_at) AS first_burn_at
  FROM loyalty_transactions lt
  WHERE lt.direction = 'burn'
  GROUP BY lt.user_id
),
member_base AS (
  SELECT
    t0.user_id AS user_id,
    t0.enrolled_at AS enrolled_at,
    t1.first_burn_at AS first_burn_at,
    CASE
      WHEN ({{date_diff_days(t0.enrolled_at, t1.first_burn_at)}}) <= 30 THEN 'within 30 days of enrollment'
      WHEN ({{date_diff_days(t0.enrolled_at, t1.first_burn_at)}}) <= 180 THEN '31 to 180 days'
      ELSE 'over 180 days'
    END AS bucket
  FROM member_enroll t0
  JOIN member_first_burn t1 ON t1.user_id = t0.user_id
),
orders_after_count AS (
  SELECT
    mb.user_id AS user_id,
    COUNT(o.id) AS orders_after_count
  FROM member_base mb
  LEFT JOIN orders o
    ON o.user_id = mb.user_id
   AND o.placed_at >= mb.first_burn_at
  GROUP BY mb.user_id
),
orders_after_revenue AS (
  SELECT
    mb.user_id AS user_id,
    SUM(
      CASE
        WHEN o.id IS NULL THEN 0
        WHEN o.currency_code = 'EUR' THEN o.grand_total
        ELSE CAST({{divide_decimal(o.grand_total, NULLIF(er.rate, 0))}} AS NUMERIC(18,6))
      END
    ) AS revenue_after_eur
  FROM member_base mb
  LEFT JOIN orders o
    ON o.user_id = mb.user_id
   AND o.placed_at >= mb.first_burn_at
   AND o.status <> 'cancelled'
  LEFT JOIN exchange_rates er
    ON er.base_code = 'EUR'
   AND er.quote_code = o.currency_code
   AND er.as_of = CAST(o.placed_at AS date)
  GROUP BY mb.user_id
)
SELECT
  mb.bucket AS time_to_first_redemption_bucket,
  COUNT(*) AS member_count,
  {{divide_decimal(100.0 * SUM(CASE WHEN COALESCE(oac.orders_after_count, 0) = 0 THEN 1 ELSE 0 END), COUNT(*))}} AS pct_with_no_orders_after_redemption,
  AVG(CAST(COALESCE(oac.orders_after_count, 0) AS NUMERIC(18,6))) AS avg_orders_after_per_customer,
  AVG(COALESCE(oar.revenue_after_eur, 0)) AS avg_revenue_after_eur
FROM member_base mb
LEFT JOIN orders_after_count oac ON oac.user_id = mb.user_id
LEFT JOIN orders_after_revenue oar ON oar.user_id = mb.user_id
GROUP BY mb.bucket
ORDER BY
  CASE mb.bucket
    WHEN 'within 30 days of enrollment' THEN 1
    WHEN '31 to 180 days' THEN 2
    WHEN 'over 180 days' THEN 3
  END NULLS LAST
