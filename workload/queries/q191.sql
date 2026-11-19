WITH adjustments_2025 AS (
    SELECT
        sm.id AS id,
        sm.tenant_id AS tenant_id,
        sm.variant_id AS variant_id,
        sm.stock_location_id AS stock_location_id,
        sm.quantity AS quantity_signed,
        sm.reference_type AS reference_type,
        sm.occurred_at AS occurred_at
    FROM stock_movements sm
    WHERE sm.kind = 'adjustment'
      AND sm.occurred_at >= DATE '2025-01-01'
      AND sm.occurred_at < DATE '2026-01-01'
),
preferred_cost AS (
    SELECT
        sp.variant_id AS variant_id,
        sp.unit_cost AS unit_cost,
        sp.currency_code AS currency_code,
        ROW_NUMBER() OVER (PARTITION BY sp.variant_id ORDER BY sp.id NULLS LAST) AS rn
    FROM supplier_products sp
    WHERE sp.is_preferred = true
),
variant_cost AS (
    SELECT variant_id, unit_cost, currency_code
    FROM preferred_cost
    WHERE rn = 1
),
fx AS (
    SELECT base_code, quote_code, rate, as_of
    FROM exchange_rates
    WHERE base_code = 'EUR'
),
enriched AS (
    SELECT
        a.id AS id,
        a.occurred_at AS occurred_at,
        t.name AS tenant_name,
        w.name AS warehouse_name,
        sl.kind AS location_kind,
        COALESCE(c.name, 'Uncategorized') AS category_name,
        pv.sku AS sku,
        a.quantity_signed AS quantity_signed,
        a.reference_type AS reference_type,
        CASE
            WHEN vc.currency_code = 'EUR' THEN ABS(a.quantity_signed) * vc.unit_cost
            ELSE CAST({{divide_decimal(ABS(a.quantity_signed) * vc.unit_cost, NULLIF(fx.rate, 0))}} AS NUMERIC(18,6))
        END AS estimated_value_eur
    FROM adjustments_2025 a
    JOIN stock_locations sl ON sl.id = a.stock_location_id
    JOIN warehouses w ON w.id = sl.warehouse_id
    JOIN tenants t ON t.id = w.tenant_id
    JOIN product_variants pv ON pv.id = a.variant_id
    JOIN products p ON p.id = pv.product_id
    LEFT JOIN categories c ON c.id = p.primary_category_id
    LEFT JOIN variant_cost vc ON vc.variant_id = a.variant_id
    LEFT JOIN fx ON fx.quote_code = vc.currency_code AND fx.as_of = CAST(a.occurred_at AS date)
)
SELECT
    occurred_at,
    tenant_name,
    warehouse_name,
    location_kind,
    category_name,
    sku,
    quantity_signed,
    estimated_value_eur AS estimated_value_eur,
    reference_type
FROM enriched
ORDER BY estimated_value_eur DESC NULLS LAST, ABS(quantity_signed) DESC NULLS FIRST, occurred_at NULLS LAST, id NULLS LAST
{{fetch_first(30)}}
