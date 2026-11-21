WITH retail_tenants AS (
    SELECT id, name
    FROM tenants
    WHERE name IN (
        'Kibblewick', 'Studio Vrij', 'Petalcourt Beauty',
        'Marrowby & Vane', 'Cragsley Outfitters', 'Ampfeld Elektronik'
    )
),
all_orders AS (
    SELECT o.id AS id, o.tenant_id AS tenant_id, o.user_id AS user_id, o.placed_at AS placed_at
    FROM orders o
    JOIN retail_tenants rt ON rt.id = o.tenant_id
    WHERE o.placed_at IS NOT NULL
),
base_orders AS (
    SELECT *
    FROM all_orders
    WHERE placed_at >= TIMESTAMP '2025-01-01'
      AND placed_at < TIMESTAMP '2025-10-01'
),
order_has_return AS (
    SELECT DISTINCT order_id
    FROM order_returns
),
next_order_per_base_order AS (
    SELECT b.id AS order_id, MIN(a.placed_at) AS next_placed_at
    FROM base_orders b
    JOIN all_orders a
      ON a.tenant_id = b.tenant_id
     AND a.user_id = b.user_id
     AND a.placed_at > b.placed_at
    GROUP BY b.id
),
order_level AS (
    SELECT
        b.id AS order_id,
        b.tenant_id AS tenant_id,
        b.user_id AS user_id,
        CASE WHEN ohr.order_id IS NOT NULL THEN 'has_return' ELSE 'no_return' END AS grp,
        CASE WHEN nop.next_placed_at IS NOT NULL
             THEN {{divide_decimal({{seconds_between(b.placed_at, nop.next_placed_at)}}, 86400.0)}}
        END AS days_to_next
    FROM base_orders b
    LEFT JOIN order_has_return ohr ON ohr.order_id = b.id
    LEFT JOIN next_order_per_base_order nop ON nop.order_id = b.id
)
SELECT
    grp AS "group",
    COUNT(*) AS orders_count,
    {{count_distinct_pair(tenant_id, user_id)}} AS distinct_customers,
    {{divide_decimal(100.0 * SUM(CASE WHEN days_to_next IS NOT NULL AND days_to_next <= 90 THEN 1 ELSE 0 END), COUNT(*))}} AS pct_with_subsequent_order_within_90_days,
    {{percentile_cont_filter(0.5, days_to_next, days_to_next IS NOT NULL AND days_to_next <= 90)}} AS median_days_to_subsequent_order
FROM order_level
GROUP BY grp
ORDER BY CASE WHEN grp = 'has_return' THEN 0 ELSE 1 END NULLS LAST
