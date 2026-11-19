WITH tenant_vertical AS (
  SELECT id AS tenant_id, COALESCE(NULLIF(TRIM(industry), ''), 'Unspecified') AS vertical, status
  FROM tenants
  WHERE deleted_at IS NULL
),
merchant_counts AS (
  SELECT vertical,
    COUNT(*) AS total_merchants,
    COUNT(*) FILTER (WHERE status = 'active') AS active_merchants,
    COUNT(*) FILTER (WHERE status IN ('past_due','suspended','churned')) AS at_risk_merchants
  FROM tenant_vertical
  GROUP BY vertical
),
tickets_in_window AS (
  SELECT tv.vertical AS vertical, COUNT(*) AS ticket_count
  FROM tickets t
  JOIN tenant_vertical tv ON tv.tenant_id = t.tenant_id
  WHERE t.created_at >= TIMESTAMP '2025-01-01' AND t.created_at < TIMESTAMP '2026-01-01'
  GROUP BY tv.vertical
),
csat_in_window AS (
  SELECT tv.vertical AS vertical, AVG(CAST(c.score AS NUMERIC(18,6))) AS avg_score
  FROM csat_responses c
  JOIN tickets t ON t.id = c.ticket_id
  JOIN tenant_vertical tv ON tv.tenant_id = t.tenant_id
  WHERE t.created_at >= TIMESTAMP '2025-01-01' AND t.created_at < TIMESTAMP '2026-01-01'
  GROUP BY tv.vertical
)
SELECT
  mc.vertical AS vertical,
  mc.total_merchants AS total_merchants,
  mc.active_merchants AS active_merchants,
  mc.at_risk_merchants AS at_risk_merchants,
  {{divide_decimal(CAST(COALESCE(ti.ticket_count, 0) AS numeric(18,6)), mc.total_merchants)}} AS tickets_per_merchant,
  cw.avg_score AS avg_csat_score
FROM merchant_counts mc
LEFT JOIN tickets_in_window ti ON ti.vertical = mc.vertical
LEFT JOIN csat_in_window cw ON cw.vertical = mc.vertical
ORDER BY mc.at_risk_merchants DESC NULLS FIRST, mc.vertical ASC NULLS LAST
