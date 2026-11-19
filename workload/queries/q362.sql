WITH discount_filtered AS (
  SELECT
    od0.tenant_id AS tenant_id,
    od0.order_id AS order_id,
    SUM(od0.amount) AS discount_amount,
    MIN(od0.currency_code) AS currency_code
  FROM order_discounts od0
  JOIN discounts d0
    ON d0.id = od0.discount_id
   AND d0.tenant_id = od0.tenant_id
  WHERE d0.name = 'Subscription delivery (prepaid)'
  GROUP BY od0.tenant_id, od0.order_id
),
base_orders AS (
  SELECT
    o1.id AS order_id,
    o1.tenant_id AS tenant_id,
    o1.user_id AS user_id,
    o1.placed_at AS placed_at,
    df1.discount_amount AS discount_amount,
    df1.currency_code AS discount_currency_code
  FROM orders o1
  JOIN discount_filtered df1
    ON df1.order_id = o1.id
   AND df1.tenant_id = o1.tenant_id
  WHERE o1.placed_at >= DATE '2025-01-01'
    AND o1.placed_at < DATE '2026-01-01'
    AND o1.status <> 'cancelled'
),
orphan_orders AS (
  -- Orders with the subscription-delivery discount that have no subscription
  -- covering placed_at with status in (trialing, active, past_due).
  SELECT bo2.*
  FROM base_orders bo2
  WHERE NOT EXISTS (
    SELECT 1
    FROM subscriptions s2
    WHERE s2.tenant_id = bo2.tenant_id
      AND s2.user_id = bo2.user_id
      AND s2.status IN ('trialing', 'active', 'past_due')
      AND s2.started_at <= bo2.placed_at
      AND (s2.ended_at IS NULL OR s2.ended_at >= bo2.placed_at)
  )
),
ranked_subs AS (
  SELECT
    s3.tenant_id AS tenant_id,
    s3.user_id AS user_id,
    s3.id AS subscription_id,
    s3.started_at AS started_at,
    s3.ended_at AS ended_at,
    s3.status AS status,
    ROW_NUMBER() OVER (
      PARTITION BY s3.tenant_id, s3.user_id
      ORDER BY s3.started_at DESC NULLS FIRST, s3.id DESC NULLS FIRST
    ) AS recency_rank
  FROM subscriptions s3
),
most_recent_sub AS (
  -- Each customer's most-recent subscription by started_at (the "bucket" status).
  SELECT
    rs4.tenant_id AS tenant_id,
    rs4.user_id AS user_id,
    rs4.subscription_id AS mrs_subscription_id,
    rs4.status AS mrs_status
  FROM ranked_subs rs4
  WHERE rs4.recency_rank = 1
),
active_bucket_orphans AS (
  -- The 291-order population: orphan orders for customers whose most-recent
  -- subscription is currently 'active'.
  SELECT
    oo5.order_id AS order_id,
    oo5.tenant_id AS tenant_id,
    oo5.user_id AS user_id,
    oo5.placed_at AS placed_at,
    oo5.discount_amount AS discount_amount,
    oo5.discount_currency_code AS discount_currency_code,
    mrs5.mrs_subscription_id AS mrs_subscription_id
  FROM orphan_orders oo5
  JOIN most_recent_sub mrs5
    ON mrs5.tenant_id = oo5.tenant_id
   AND mrs5.user_id = oo5.user_id
  WHERE mrs5.mrs_status = 'active'
),
classified AS (
  -- Every order is assigned to exactly one of the three mutually-exclusive
  -- categories below (LEFT/NOT EXISTS pattern, no inner join drops rows).
  SELECT
    abo6.order_id AS order_id,
    abo6.tenant_id AS tenant_id,
    abo6.user_id AS user_id,
    abo6.placed_at AS placed_at,
    abo6.discount_amount AS discount_amount,
    abo6.discount_currency_code AS discount_currency_code,
    CASE
      WHEN NOT EXISTS (
        SELECT 1
        FROM subscriptions s7
        WHERE s7.tenant_id = abo6.tenant_id
          AND s7.user_id = abo6.user_id
          AND s7.id <> abo6.mrs_subscription_id
          AND s7.started_at <= abo6.placed_at
      ) THEN 'preceded first-ever subscription'
      WHEN EXISTS (
        SELECT 1
        FROM subscriptions s8
        WHERE s8.tenant_id = abo6.tenant_id
          AND s8.user_id = abo6.user_id
          AND s8.id <> abo6.mrs_subscription_id
          AND s8.started_at <= abo6.placed_at
          AND (s8.ended_at IS NULL OR s8.ended_at >= abo6.placed_at)
      ) THEN 'unexplained'
      ELSE 'fell between two subscription stints'
    END AS category
  FROM active_bucket_orphans abo6
),
converted AS (
  SELECT
    c9.category AS category,
    c9.order_id AS order_id,
    c9.tenant_id AS tenant_id,
    c9.user_id AS user_id,
    CAST(c9.tenant_id AS varchar) || ':' || CAST(c9.user_id AS varchar) AS customer_key,
    CASE
      WHEN c9.discount_currency_code = 'EUR' THEN c9.discount_amount
      ELSE CAST({{divide_decimal(c9.discount_amount, NULLIF(er9.rate, 0))}} AS NUMERIC(18,6))
    END AS discount_amount_eur
  FROM classified c9
  LEFT JOIN exchange_rates er9
    ON er9.base_code = 'EUR'
   AND er9.quote_code = c9.discount_currency_code
   AND er9.as_of = CAST(c9.placed_at AS date)
),
totals AS (
  SELECT COUNT(*) AS total_orders FROM converted
)
SELECT
  conv10.category AS category,
  COUNT(*) AS order_count,
  {{divide_decimal(100.0 * COUNT(*), t10.total_orders)}} AS pct_of_bucket,
  COUNT(DISTINCT conv10.customer_key) AS distinct_customers,
  SUM(conv10.discount_amount_eur) AS total_discount_eur
FROM converted conv10
CROSS JOIN totals t10
GROUP BY conv10.category, t10.total_orders
ORDER BY order_count DESC NULLS FIRST, conv10.category ASC NULLS LAST
