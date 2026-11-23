WITH cancelled_orders AS (
    SELECT
        id AS order_id,
        tenant_id
    FROM orders
    WHERE status = 'cancelled'
),
joined AS (
    SELECT
        co.tenant_id AS tenant_id,
        co.order_id AS order_id,
        h.id AS history_id,
        h.changed_by_user_id AS changed_by_user_id
    FROM cancelled_orders co
    LEFT JOIN order_status_history h
        ON h.order_id = co.order_id
        AND h.to_status = 'cancelled'
        AND h.tenant_id = co.tenant_id
),
per_tenant AS (
    SELECT
        tenant_id,
        COUNT(DISTINCT order_id) AS cancelled_orders,
        COUNT(history_id) AS matching_history_rows,
        COUNT(DISTINCT CASE WHEN history_id IS NOT NULL THEN order_id END) AS orders_with_match,
        COUNT(CASE WHEN changed_by_user_id IS NOT NULL THEN 1 END) AS matching_rows_with_actor
    FROM joined
    GROUP BY tenant_id
)
SELECT
    t.name AS tenant_name,
    pt.cancelled_orders AS cancelled_orders,
    pt.matching_history_rows AS matching_history_rows,
    {{divide_decimal(100.0 * pt.orders_with_match, pt.cancelled_orders)}} AS coverage_rate_pct,
    pt.matching_rows_with_actor AS matching_rows_with_actor
FROM per_tenant pt
JOIN tenants t ON t.id = pt.tenant_id
ORDER BY
    coverage_rate_pct ASC NULLS LAST,
    pt.cancelled_orders DESC NULLS FIRST,
    tenant_name ASC NULLS LAST,
    pt.tenant_id ASC NULLS LAST
{{fetch_first(50)}}
