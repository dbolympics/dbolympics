WITH po_quarters AS (
  SELECT
    po.id AS id,
    po.status AS status,
    po.ordered_at AS ordered_at,
    po.expected_at AS expected_at,
    po.received_at AS received_at,
    cd.quarter_num AS quarter_num
  FROM purchase_orders po
  JOIN calendar_days cd ON cd.calendar_date = CAST(po.ordered_at AS date)
  WHERE po.ordered_at >= DATE '2025-01-01'
    AND po.ordered_at < DATE '2026-01-01'
),
received_lead AS (
  SELECT quarter_num,
    {{divide_decimal({{seconds_between(ordered_at, received_at)}}, 86400.0)}} AS lead_days
  FROM po_quarters
  WHERE received_at IS NOT NULL
),
late_subset AS (
  SELECT quarter_num,
    {{divide_decimal({{seconds_between(expected_at, received_at)}}, 86400.0)}} AS days_late
  FROM po_quarters
  WHERE received_at IS NOT NULL AND expected_at IS NOT NULL AND received_at > expected_at
),
both_dates AS (
  SELECT quarter_num
  FROM po_quarters
  WHERE received_at IS NOT NULL AND expected_at IS NOT NULL
),
quarter_summary AS (
  SELECT
    quarter_num,
    COUNT(*) AS pos_ordered,
    COUNT(received_at) AS pos_received,
    SUM(CASE WHEN status IN ('submitted','partially_received') AND received_at IS NULL THEN 1 ELSE 0 END) AS pos_still_open_at_cutoff
  FROM po_quarters
  GROUP BY quarter_num
),
lead_summary AS (
  SELECT quarter_num, AVG(lead_days) AS avg_actual_lead_days
  FROM received_lead
  GROUP BY quarter_num
),
late_summary AS (
  SELECT quarter_num, AVG(days_late) AS avg_days_late, COUNT(*) AS late_count
  FROM late_subset
  GROUP BY quarter_num
),
both_summary AS (
  SELECT quarter_num, COUNT(*) AS both_count
  FROM both_dates
  GROUP BY quarter_num
)
SELECT
  '2025-Q' || qs.quarter_num AS quarter,
  qs.pos_ordered AS pos_ordered,
  qs.pos_received AS pos_received,
  ls.avg_actual_lead_days AS avg_actual_lead_days,
  ({{divide_decimal(CAST(COALESCE(lt.late_count,0) AS numeric(18,6)), NULLIF(bd.both_count,0))}}) * 100 AS pct_received_late,
  lt.avg_days_late AS avg_days_late,
  qs.pos_still_open_at_cutoff AS pos_still_open_at_cutoff
FROM quarter_summary qs
LEFT JOIN lead_summary ls ON ls.quarter_num = qs.quarter_num
LEFT JOIN late_summary lt ON lt.quarter_num = qs.quarter_num
LEFT JOIN both_summary bd ON bd.quarter_num = qs.quarter_num
ORDER BY qs.quarter_num NULLS LAST
