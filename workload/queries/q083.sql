SELECT
    t.name AS tenant_name,
    b.bucket AS bucket,
    COUNT(*) AS cart_count,
    {{divide_decimal(100.0 * COUNT(*), SUM(COUNT(*)) OVER (PARTITION BY t.name))}} AS pct_of_tenant_carts,
    {{divide_decimal(100.0 * SUM(CASE WHEN b.status = 'converted' THEN 1 ELSE 0 END), COUNT(*))}} AS converted_pct
FROM (
    SELECT
        c.tenant_id AS tenant_id,
        c.status AS status,
        CASE
            WHEN c.converted_at IS NULL AND c.abandoned_at IS NULL AND c.expires_at IS NULL
                THEN 'unresolved/still active'
            WHEN {{divide_decimal({{seconds_between(c.created_at, COALESCE(c.converted_at, c.abandoned_at, c.expires_at))}}, 3600.0)}} < 1
                THEN '<1 hour'
            WHEN {{divide_decimal({{seconds_between(c.created_at, COALESCE(c.converted_at, c.abandoned_at, c.expires_at))}}, 3600.0)}} < 24
                THEN '1-24 hours'
            WHEN {{divide_decimal({{seconds_between(c.created_at, COALESCE(c.converted_at, c.abandoned_at, c.expires_at))}}, 3600.0)}} < 168
                THEN '1-7 days'
            ELSE '>7 days'
        END AS bucket
    FROM carts c
    WHERE c.created_at >= DATE '2025-10-01' AND c.created_at < DATE '2026-01-01'
) b
JOIN tenants t ON t.id = b.tenant_id
WHERE t.name IN ('Kibblewick', 'Studio Vrij', 'Petalcourt Beauty', 'Marrowby & Vane', 'Cragsley Outfitters', 'Ampfeld Elektronik')
GROUP BY t.name, b.bucket
ORDER BY t.name NULLS LAST,
    CASE b.bucket
        WHEN '<1 hour' THEN 1
        WHEN '1-24 hours' THEN 2
        WHEN '1-7 days' THEN 3
        WHEN '>7 days' THEN 4
        WHEN 'unresolved/still active' THEN 5
    END NULLS LAST
