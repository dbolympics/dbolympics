WITH discount_order_lines AS (
    SELECT
        t1.id AS order_discount_id,
        t1.tenant_id AS tenant_id,
        t1.order_id AS order_id,
        t1.discount_id AS discount_id,
        t1.code AS coupon_code,
        t1.amount AS discount_amount,
        t1.currency_code AS discount_currency_code,
        t2.user_id AS user_id,
        t2.placed_at AS placed_at,
        t2.currency_code AS order_currency_code,
        t2.grand_total AS order_grand_total,
        t3.name AS discount_name
    FROM order_discounts t1
    JOIN orders t2
        ON t2.id = t1.order_id
       AND t2.tenant_id = t1.tenant_id
    JOIN discounts t3
        ON t3.id = t1.discount_id
       AND t3.tenant_id = t1.tenant_id
    WHERE t2.status <> 'cancelled'
      AND t2.placed_at >= DATE '2025-01-01'
      AND t2.placed_at < DATE '2026-01-01'
      AND t3.name <> 'Subscription delivery (prepaid)'
),
discount_order_lines_eur AS (
    SELECT
        t4.*,
        CAST({{divide_decimal(t4.discount_amount, NULLIF(t5.rate, 0))}} AS NUMERIC(18,6)) AS discount_amount_eur,
        CAST({{divide_decimal(t4.order_grand_total, NULLIF(t6.rate, 0))}} AS NUMERIC(18,6)) AS order_grand_total_eur
    FROM discount_order_lines t4
    LEFT JOIN exchange_rates t5
        ON t5.base_code = 'EUR'
       AND t5.quote_code = t4.discount_currency_code
       AND t5.as_of = CAST(t4.placed_at AS DATE)
    LEFT JOIN exchange_rates t6
        ON t6.base_code = 'EUR'
       AND t6.quote_code = t4.order_currency_code
       AND t6.as_of = CAST(t4.placed_at AS DATE)
),
discounted_orders_distinct AS (
    SELECT DISTINCT
        discount_id,
        discount_name,
        tenant_id,
        order_id,
        user_id,
        order_grand_total_eur
    FROM discount_order_lines_eur
),
discount_spend AS (
    SELECT
        discount_id,
        discount_name,
        SUM(discount_amount_eur) AS total_discount_spend_eur
    FROM discount_order_lines_eur
    GROUP BY discount_id, discount_name
),
top_discounts AS (
    SELECT discount_id, discount_name, total_discount_spend_eur
    FROM discount_spend
    ORDER BY total_discount_spend_eur DESC NULLS FIRST, discount_id NULLS LAST
    {{fetch_first(15)}}
),
discount_order_count AS (
    SELECT discount_id, COUNT(DISTINCT order_id) AS order_count
    FROM discounted_orders_distinct
    GROUP BY discount_id
),
discount_customer_count AS (
    SELECT discount_id, COUNT(DISTINCT user_id) AS distinct_customers
    FROM discounted_orders_distinct
    GROUP BY discount_id
),
discount_avg_value AS (
    SELECT discount_id, AVG(order_grand_total_eur) AS avg_discounted_order_value_eur
    FROM discounted_orders_distinct
    GROUP BY discount_id
),
discount_coupon_code AS (
    SELECT discount_id, MAX(coupon_code) AS coupon_code
    FROM discount_order_lines_eur
    GROUP BY discount_id
),
customer_discount_pairs AS (
    SELECT DISTINCT discount_id, tenant_id, user_id
    FROM discounted_orders_distinct
    WHERE discount_id IN (SELECT discount_id FROM top_discounts)
),
non_discounted_orders AS (
    SELECT
        t7.id AS order_id,
        t7.tenant_id AS tenant_id,
        t7.user_id AS user_id,
        t7.placed_at AS placed_at,
        t7.currency_code AS currency_code,
        t7.grand_total AS grand_total
    FROM orders t7
    WHERE t7.status <> 'cancelled'
      AND t7.placed_at >= DATE '2025-01-01'
      AND t7.placed_at < DATE '2026-01-01'
      AND NOT EXISTS (
          SELECT 1 FROM order_discounts t8
          WHERE t8.order_id = t7.id AND t8.tenant_id = t7.tenant_id
      )
),
non_discounted_orders_eur AS (
    SELECT
        t9.*,
        CAST({{divide_decimal(t9.grand_total, NULLIF(t10.rate, 0))}} AS NUMERIC(18,6)) AS grand_total_eur
    FROM non_discounted_orders t9
    LEFT JOIN exchange_rates t10
        ON t10.base_code = 'EUR'
       AND t10.quote_code = t9.currency_code
       AND t10.as_of = CAST(t9.placed_at AS DATE)
),
comparison_orders AS (
    SELECT
        t11.discount_id AS discount_id,
        t11.user_id AS user_id,
        t12.order_id AS order_id,
        t12.grand_total_eur AS grand_total_eur
    FROM customer_discount_pairs t11
    JOIN non_discounted_orders_eur t12
        ON t12.tenant_id = t11.tenant_id
       AND t12.user_id = t11.user_id
),
discount_comparison_avg AS (
    SELECT discount_id, AVG(grand_total_eur) AS avg_other_order_value_eur
    FROM comparison_orders
    GROUP BY discount_id
),
discount_comparison_customers AS (
    SELECT discount_id, COUNT(DISTINCT user_id) AS customers_with_other_orders
    FROM comparison_orders
    GROUP BY discount_id
)
SELECT
    t0.discount_name AS discount_name,
    COALESCE(t13.coupon_code, 'automatic') AS coupon_code,
    COALESCE(t14.order_count, 0) AS discounted_order_count,
    COALESCE(t15.distinct_customers, 0) AS distinct_customers,
    COALESCE(t16.avg_discounted_order_value_eur, 0) AS avg_discounted_order_value_eur,
    t17.avg_other_order_value_eur AS avg_other_order_value_eur,
    COALESCE(t16.avg_discounted_order_value_eur, 0) - t17.avg_other_order_value_eur AS lift_eur,
    (COALESCE(t16.avg_discounted_order_value_eur, 0) - t17.avg_other_order_value_eur)
    / NULLIF(t17.avg_other_order_value_eur, 0) * 100 AS lift_pct,
    {{divide_decimal(CAST(COALESCE(t18.customers_with_other_orders, 0) AS DECIMAL(18,6)), NULLIF(t15.distinct_customers, 0))}} * 100 AS pct_customers_with_other_nondiscounted_order
FROM top_discounts t0
LEFT JOIN discount_coupon_code t13 ON t13.discount_id = t0.discount_id
LEFT JOIN discount_order_count t14 ON t14.discount_id = t0.discount_id
LEFT JOIN discount_customer_count t15 ON t15.discount_id = t0.discount_id
LEFT JOIN discount_avg_value t16 ON t16.discount_id = t0.discount_id
LEFT JOIN discount_comparison_avg t17 ON t17.discount_id = t0.discount_id
LEFT JOIN discount_comparison_customers t18 ON t18.discount_id = t0.discount_id
ORDER BY lift_pct ASC NULLS LAST, discount_name ASC NULLS LAST, t0.discount_id ASC NULLS LAST
