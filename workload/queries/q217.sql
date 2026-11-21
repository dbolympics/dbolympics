WITH tenant_industry AS (
    SELECT
        id AS tenant_id,
        COALESCE(NULLIF(TRIM(industry), ''), 'Unspecified') AS vertical
    FROM tenants
),

payout_totals AS (
    SELECT
        p.tenant_id AS tenant_id,
        SUM(CAST({{divide_decimal(p.gross_amount, er.rate)}} AS NUMERIC(18,6))) AS gross_eur,
        SUM(CAST({{divide_decimal(p.fee_amount, er.rate)}} AS NUMERIC(18,6))) AS fee_eur
    FROM payouts p
    JOIN exchange_rates er
        ON er.base_code = 'EUR'
        AND er.quote_code = p.currency_code
        AND er.as_of = CAST(p.paid_at AS date)
    WHERE p.status = 'paid'
        AND p.paid_at >= DATE '2025-01-01'
        AND p.paid_at < DATE '2026-01-01'
    GROUP BY p.tenant_id
),

refund_totals AS (
    SELECT
        r.tenant_id AS tenant_id,
        SUM(CAST({{divide_decimal(r.refund_total, er.rate)}} AS NUMERIC(18,6))) AS refund_eur
    FROM order_returns r
    JOIN exchange_rates er
        ON er.base_code = 'EUR'
        AND er.quote_code = r.currency_code
        AND er.as_of = CAST(COALESCE(r.refunded_at, r.requested_at) AS date)
    WHERE r.status = 'refunded'
        AND COALESCE(r.refunded_at, r.requested_at) >= DATE '2025-01-01'
        AND COALESCE(r.refunded_at, r.requested_at) < DATE '2026-01-01'
    GROUP BY r.tenant_id
),

shipping_totals AS (
    SELECT
        o.tenant_id AS tenant_id,
        SUM(CAST({{divide_decimal(s.shipping_cost, er.rate)}} AS NUMERIC(18,6))) AS shipping_eur
    FROM shipments s
    JOIN fulfillments f ON f.id = s.fulfillment_id
    JOIN orders o ON o.id = f.order_id
    JOIN exchange_rates er
        ON er.base_code = 'EUR'
        AND er.quote_code = s.currency_code
        AND er.as_of = CAST(s.shipped_at AS date)
    WHERE s.shipped_at >= DATE '2025-01-01'
        AND s.shipped_at < DATE '2026-01-01'
        AND s.shipping_cost IS NOT NULL
    GROUP BY o.tenant_id
),

order_counts AS (
    SELECT
        tenant_id,
        COUNT(*) AS order_count
    FROM orders
    WHERE status IN ('paid', 'partially_fulfilled', 'fulfilled', 'refunded')
        AND placed_at >= DATE '2025-01-01'
        AND placed_at < DATE '2026-01-01'
    GROUP BY tenant_id
),

ticket_counts AS (
    SELECT
        tenant_id,
        COUNT(*) AS ticket_count
    FROM tickets
    WHERE created_at >= DATE '2025-01-01'
        AND created_at < DATE '2026-01-01'
    GROUP BY tenant_id
),

merchant_counts AS (
    SELECT
        vertical,
        COUNT(*) AS merchant_count
    FROM tenant_industry
    GROUP BY vertical
),

tenant_metrics AS (
    SELECT
        ti.tenant_id AS tenant_id,
        ti.vertical AS vertical,
        COALESCE(pt.gross_eur, 0) AS gross_eur,
        COALESCE(pt.fee_eur, 0) AS fee_eur,
        COALESCE(rt.refund_eur, 0) AS refund_eur,
        COALESCE(st.shipping_eur, 0) AS shipping_eur,
        COALESCE(oc.order_count, 0) AS order_count,
        COALESCE(tc.ticket_count, 0) AS ticket_count
    FROM tenant_industry ti
    LEFT JOIN payout_totals pt ON pt.tenant_id = ti.tenant_id
    LEFT JOIN refund_totals rt ON rt.tenant_id = ti.tenant_id
    LEFT JOIN shipping_totals st ON st.tenant_id = ti.tenant_id
    LEFT JOIN order_counts oc ON oc.tenant_id = ti.tenant_id
    LEFT JOIN ticket_counts tc ON tc.tenant_id = ti.tenant_id
),

vertical_agg AS (
    SELECT
        vertical,
        SUM(gross_eur) AS gross_eur,
        SUM(fee_eur) AS fee_eur,
        SUM(refund_eur) AS refund_eur,
        SUM(shipping_eur) AS shipping_eur,
        SUM(order_count) AS order_count,
        SUM(ticket_count) AS ticket_count
    FROM tenant_metrics
    GROUP BY vertical
)

SELECT
    va.vertical AS vertical,
    mc.merchant_count AS merchant_count,
    va.gross_eur AS gross_payment_volume_eur,
    va.fee_eur AS fee_revenue_eur,
    CASE WHEN va.gross_eur = 0 THEN NULL ELSE {{divide_decimal(100.0 * va.fee_eur, va.gross_eur)}} END AS take_rate_pct,
    CASE WHEN va.gross_eur = 0 THEN NULL ELSE {{divide_decimal(100.0 * va.refund_eur, va.gross_eur)}} END AS refund_rate_pct,
    CASE WHEN va.gross_eur = 0 THEN NULL ELSE {{divide_decimal(100.0 * va.shipping_eur, va.gross_eur)}} END AS shipping_cost_rate_pct,
    va.order_count AS order_count_2025,
    CASE WHEN va.order_count = 0 THEN NULL ELSE {{divide_decimal(100.0 * va.ticket_count, va.order_count)}} END AS tickets_per_100_orders
FROM vertical_agg va
JOIN merchant_counts mc ON mc.vertical = va.vertical
ORDER BY va.gross_eur DESC NULLS FIRST, va.vertical ASC NULLS LAST
