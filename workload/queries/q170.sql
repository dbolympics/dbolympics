WITH eligible_users AS (
    SELECT DISTINCT
        o.user_id AS user_id,
        o.tenant_id AS tenant_id,
        t.industry AS industry
    FROM orders o
    JOIN tenants t ON t.id = o.tenant_id
    JOIN users u ON u.id = o.user_id AND u.tenant_id = o.tenant_id
    WHERE o.placed_at >= DATE '2023-01-01'
      AND o.placed_at < DATE '2026-01-01'
      AND u.is_staff = false
),
loyalty_flags AS (
    SELECT DISTINCT tenant_id, user_id
    FROM loyalty_accounts
),
user_segment AS (
    SELECT
        eu.tenant_id AS tenant_id,
        eu.user_id AS user_id,
        eu.industry AS industry,
        CASE WHEN lf.user_id IS NOT NULL THEN 'loyalty member' ELSE 'non-member' END AS segment
    FROM eligible_users eu
    LEFT JOIN loyalty_flags lf
        ON lf.tenant_id = eu.tenant_id AND lf.user_id = eu.user_id
),
all_orders_for_users AS (
    SELECT
        o.id AS order_id,
        o.tenant_id AS tenant_id,
        o.user_id AS user_id,
        o.status AS status,
        o.placed_at AS placed_at,
        o.currency_code AS currency_code,
        o.grand_total AS grand_total
    FROM orders o
    JOIN user_segment us
        ON us.tenant_id = o.tenant_id AND us.user_id = o.user_id
),
refund_flags AS (
    SELECT
        ao.order_id AS order_id,
        CASE WHEN EXISTS (
                SELECT 1 FROM payments p
                WHERE p.order_id = ao.order_id AND p.amount_refunded > 0
             )
             OR EXISTS (
                SELECT 1 FROM order_returns r
                WHERE r.order_id = ao.order_id
             )
        THEN 1 ELSE 0 END AS is_refunded
    FROM all_orders_for_users ao
),
order_value_eur AS (
    SELECT
        ao.order_id AS order_id,
        ao.tenant_id AS tenant_id,
        ao.user_id AS user_id,
        CAST({{divide_decimal(ao.grand_total, er.rate)}} AS NUMERIC(18,6)) AS order_value_eur
    FROM all_orders_for_users ao
    LEFT JOIN exchange_rates er
        ON er.base_code = 'EUR'
        AND er.quote_code = ao.currency_code
        AND er.as_of = CAST(ao.placed_at AS DATE)
    WHERE ao.status <> 'cancelled'
),
per_user_stats AS (
    SELECT
        us.tenant_id AS tenant_id,
        us.user_id AS user_id,
        us.industry AS industry,
        us.segment AS segment,
        COUNT(ao.order_id) AS lifetime_order_count
    FROM user_segment us
    LEFT JOIN all_orders_for_users ao
        ON ao.tenant_id = us.tenant_id AND ao.user_id = us.user_id
    GROUP BY us.tenant_id, us.user_id, us.industry, us.segment
),
industry_segment_counts AS (
    SELECT
        industry,
        segment,
        COUNT(DISTINCT user_id) AS customer_count,
        AVG(CAST(lifetime_order_count AS NUMERIC(18,6))) AS avg_lifetime_orders
    FROM per_user_stats
    GROUP BY industry, segment
),
order_value_agg AS (
    SELECT
        us.industry AS industry,
        us.segment AS segment,
        AVG(ov.order_value_eur) AS avg_order_value_eur
    FROM order_value_eur ov
    JOIN user_segment us
        ON us.tenant_id = ov.tenant_id AND us.user_id = ov.user_id
    GROUP BY us.industry, us.segment
),
refund_agg AS (
    SELECT
        us.industry AS industry,
        us.segment AS segment,
        AVG(CAST(rf.is_refunded AS DECIMAL(18,6))) * 100 AS refund_rate_pct
    FROM refund_flags rf
    JOIN all_orders_for_users ao ON ao.order_id = rf.order_id
    JOIN user_segment us
        ON us.tenant_id = ao.tenant_id AND us.user_id = ao.user_id
    GROUP BY us.industry, us.segment
),
qualifying_industries AS (
    SELECT industry
    FROM industry_segment_counts
    GROUP BY industry
    HAVING COUNT(DISTINCT segment) = 2 AND MIN(customer_count) >= 20
)
SELECT
    isc.industry AS industry,
    isc.segment AS segment,
    isc.customer_count AS customer_count,
    isc.avg_lifetime_orders AS avg_lifetime_orders,
    ova.avg_order_value_eur AS avg_order_value_eur,
    ra.refund_rate_pct AS refund_rate_pct
FROM industry_segment_counts isc
JOIN qualifying_industries qi ON qi.industry = isc.industry
LEFT JOIN order_value_agg ova ON ova.industry = isc.industry AND ova.segment = isc.segment
LEFT JOIN refund_agg ra ON ra.industry = isc.industry AND ra.segment = isc.segment
ORDER BY isc.industry NULLS LAST, (CASE WHEN isc.segment = 'loyalty member' THEN 0 ELSE 1 END) NULLS LAST
