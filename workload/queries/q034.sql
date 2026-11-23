SELECT
  s.name AS supplier_name,
  s.lead_time_days AS lead_time_days_contracted,
  agg.pos_ordered AS pos_ordered,
  agg.pos_received AS pos_received,
  agg.avg_actual_lead_days AS avg_actual_lead_days,
  agg.pct_received_late AS pct_received_late,
  agg.avg_days_late AS avg_days_late
FROM suppliers s
JOIN (
  SELECT
    po.supplier_id AS supplier_id,
    COUNT(*) AS pos_ordered,
    COUNT(po.received_at) AS pos_received,
    AVG(CAST(CASE WHEN po.received_at IS NOT NULL THEN ({{date_diff_days(po.ordered_at, po.received_at)}}) END AS NUMERIC(18,6))) AS avg_actual_lead_days,
    {{divide_decimal(100.0 * SUM(CASE WHEN po.expected_at IS NOT NULL AND po.received_at IS NOT NULL AND po.received_at > po.expected_at THEN 1 ELSE 0 END), NULLIF(SUM(CASE WHEN po.expected_at IS NOT NULL AND po.received_at IS NOT NULL THEN 1 ELSE 0 END), 0))}} AS pct_received_late,
    AVG(CAST(CASE WHEN po.expected_at IS NOT NULL AND po.received_at IS NOT NULL AND po.received_at > po.expected_at
             THEN ({{date_diff_days(po.expected_at, po.received_at)}}) END AS NUMERIC(18,6))) AS avg_days_late
  FROM purchase_orders po
  WHERE po.ordered_at >= DATE '2025-01-01' AND po.ordered_at < DATE '2026-01-01'
  GROUP BY po.supplier_id
  HAVING COUNT(*) >= 10
) agg ON agg.supplier_id = s.id
ORDER BY agg.pos_ordered DESC NULLS FIRST, s.name ASC NULLS LAST, s.id NULLS LAST
{{fetch_first(50)}}
