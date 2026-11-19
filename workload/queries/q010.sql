WITH active_tenants AS (
    SELECT
        id AS tenant_id,
        status AS tenant_status,
        created_at
    FROM tenants
    WHERE deleted_at IS NULL
),
recent_paid_payouts AS (
    SELECT DISTINCT tenant_id
    FROM payouts
    WHERE status = 'paid'
      AND paid_at >= DATE '2025-01-01'
      AND paid_at < DATE '2026-01-01'
),
tenant_payout_flags AS (
    SELECT
        t.tenant_id AS tenant_id,
        t.tenant_status AS tenant_status,
        t.created_at AS created_at,
        CASE WHEN p.tenant_id IS NOT NULL THEN 1 ELSE 0 END AS has_recent_payout,
        (DATE '2026-01-05' - CAST(t.created_at AS DATE)) AS tenure_days
    FROM active_tenants t
    LEFT JOIN recent_paid_payouts p
        ON p.tenant_id = t.tenant_id
)
SELECT
    tenant_status,
    COUNT(*) AS tenant_count,
    SUM(has_recent_payout) AS with_recent_payout,
    SUM(1 - has_recent_payout) AS without_recent_payout,
    {{divide_decimal(100.0 * SUM(1 - has_recent_payout), COUNT(*))}} AS pct_without_recent_payout,
    AVG(CAST(CASE WHEN has_recent_payout = 0 THEN tenure_days END AS NUMERIC(18,6))) AS avg_tenure_days_without_payout
FROM tenant_payout_flags
GROUP BY tenant_status
ORDER BY tenant_count DESC NULLS FIRST, tenant_status ASC NULLS LAST
