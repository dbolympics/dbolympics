WITH eligible_orders AS (
    SELECT
        o.id AS order_id,
        o.tenant_id AS tenant_id,
        o.grand_total AS grand_total,
        o.currency_code AS currency_code,
        o.placed_at AS placed_at
    FROM orders o
    WHERE o.placed_at >= DATE '2025-01-01'
      AND o.placed_at < DATE '2026-01-01'
      AND o.status <> 'cancelled'
),
order_revenue_eur AS (
    SELECT
        eo.tenant_id AS tenant_id,
        eo.order_id AS order_id,
        CAST({{divide_decimal(eo.grand_total, er.rate)}} AS NUMERIC(18,6)) AS revenue_eur
    FROM eligible_orders eo
    JOIN exchange_rates er
      ON er.base_code = 'EUR'
     AND er.quote_code = eo.currency_code
     AND er.as_of = CAST(eo.placed_at AS DATE)
),
tenant_order_totals AS (
    SELECT
        tenant_id,
        SUM(revenue_eur) AS total_revenue_eur,
        COUNT(DISTINCT order_id) AS order_count
    FROM order_revenue_eur
    GROUP BY tenant_id
),
discount_detail AS (
    SELECT
        od.tenant_id AS tenant_id,
        od.order_id AS order_id,
        CAST({{divide_decimal(od.amount, er.rate)}} AS NUMERIC(18,6)) AS discount_eur,
        COALESCE(CAST(od.coupon_id AS varchar), od.code) AS discount_code_key
    FROM order_discounts od
    JOIN eligible_orders eo
      ON eo.order_id = od.order_id
     AND eo.tenant_id = od.tenant_id
    JOIN exchange_rates er
      ON er.base_code = 'EUR'
     AND er.quote_code = od.currency_code
     AND er.as_of = CAST(eo.placed_at AS DATE)
),
tenant_discount_totals AS (
    SELECT
        tenant_id,
        SUM(discount_eur) AS total_discount_eur,
        COUNT(DISTINCT discount_code_key) AS distinct_discount_codes
    FROM discount_detail
    GROUP BY tenant_id
),
combined AS (
    SELECT
        t.name AS tenant_name,
        t.industry AS vertical,
        COALESCE(td.total_discount_eur, 0) AS discount_eur,
        ot.total_revenue_eur AS revenue_eur,
        ot.order_count AS order_count,
        COALESCE(td.distinct_discount_codes, 0) AS distinct_discount_codes
    FROM tenant_order_totals ot
    JOIN tenants t ON t.id = ot.tenant_id
    LEFT JOIN tenant_discount_totals td ON td.tenant_id = ot.tenant_id
)
SELECT
    tenant_name,
    vertical,
    discount_eur AS discount_amount_eur,
    revenue_eur AS order_revenue_eur,
    {{divide_decimal(discount_eur, NULLIF(revenue_eur, 0))}} * 100 AS discount_pct_of_revenue,
    order_count,
    distinct_discount_codes,
    {{divide_decimal(discount_eur, NULLIF(SUM(discount_eur) OVER (), 0))}} * 100 AS share_of_company_discount_pct
FROM combined
ORDER BY discount_amount_eur DESC NULLS FIRST, tenant_name NULLS LAST, vertical NULLS LAST, order_revenue_eur NULLS LAST, discount_pct_of_revenue NULLS LAST, order_count NULLS LAST, distinct_discount_codes NULLS LAST, share_of_company_discount_pct NULLS LAST
{{fetch_first(50)}}
