SELECT
  t0.id AS tenant_id,
  t0.name AS merchant_name,
  t1.response_count AS response_count,
  t2.avg_score AS avg_score,
  t3.median_score AS median_score,
  t4.pct_satisfied AS pct_satisfied,
  t5.pct_dissatisfied AS pct_dissatisfied
FROM tenants t0
JOIN (
  SELECT tenant_id, COUNT(*) AS response_count
  FROM csat_responses
  WHERE submitted_at >= DATE '2025-01-01' AND submitted_at < DATE '2026-01-01'
  GROUP BY tenant_id
  HAVING COUNT(*) >= 10
) t1 ON t1.tenant_id = t0.id
JOIN (
  SELECT tenant_id, AVG(CAST(score AS NUMERIC(18,6))) AS avg_score
  FROM csat_responses
  WHERE submitted_at >= DATE '2025-01-01' AND submitted_at < DATE '2026-01-01'
  GROUP BY tenant_id
) t2 ON t2.tenant_id = t0.id
JOIN (
  SELECT tenant_id, {{percentile_cont(0.5, score)}} AS median_score
  FROM csat_responses
  WHERE submitted_at >= DATE '2025-01-01' AND submitted_at < DATE '2026-01-01'
  GROUP BY tenant_id
) t3 ON t3.tenant_id = t0.id
JOIN (
  SELECT tenant_id,
    {{divide_decimal(100.0 * SUM(CASE WHEN score >= 4 THEN 1 ELSE 0 END), COUNT(*))}} AS pct_satisfied
  FROM csat_responses
  WHERE submitted_at >= DATE '2025-01-01' AND submitted_at < DATE '2026-01-01'
  GROUP BY tenant_id
) t4 ON t4.tenant_id = t0.id
JOIN (
  SELECT tenant_id,
    {{divide_decimal(100.0 * SUM(CASE WHEN score <= 2 THEN 1 ELSE 0 END), COUNT(*))}} AS pct_dissatisfied
  FROM csat_responses
  WHERE submitted_at >= DATE '2025-01-01' AND submitted_at < DATE '2026-01-01'
  GROUP BY tenant_id
) t5 ON t5.tenant_id = t0.id
ORDER BY t2.avg_score ASC NULLS LAST, t0.name ASC NULLS LAST, t0.id ASC NULLS LAST
{{fetch_first(50)}}
