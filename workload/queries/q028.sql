WITH grain AS (
  SELECT DISTINCT t0.carrier AS carrier, t1.quarter_start AS quarter_start, t1.year_num AS year_num, t1.quarter_num AS quarter_num
  FROM shipments t0
  JOIN calendar_days t1 ON t1.calendar_date = CAST(t0.shipped_at AS date)
  WHERE t0.shipped_at >= DATE '2025-01-01' AND t0.shipped_at < DATE '2026-01-01'
),
m_shipped AS (
  SELECT t0.carrier AS carrier, t1.quarter_start AS quarter_start, COUNT(*) AS shipments_shipped
  FROM shipments t0
  JOIN calendar_days t1 ON t1.calendar_date = CAST(t0.shipped_at AS date)
  WHERE t0.shipped_at >= DATE '2025-01-01' AND t0.shipped_at < DATE '2026-01-01'
  GROUP BY t0.carrier, t1.quarter_start
),
m_delivered AS (
  SELECT t0.carrier AS carrier, t1.quarter_start AS quarter_start, COUNT(*) AS shipments_delivered
  FROM shipments t0
  JOIN calendar_days t1 ON t1.calendar_date = CAST(t0.shipped_at AS date)
  WHERE t0.shipped_at >= DATE '2025-01-01' AND t0.shipped_at < DATE '2026-01-01'
    AND t0.delivered_at IS NOT NULL
  GROUP BY t0.carrier, t1.quarter_start
),
m_avg AS (
  SELECT t0.carrier AS carrier, t1.quarter_start AS quarter_start,
    AVG(CAST({{date_diff_days(t0.shipped_at, t0.delivered_at)}} AS NUMERIC(18,6))) AS avg_transit_days
  FROM shipments t0
  JOIN calendar_days t1 ON t1.calendar_date = CAST(t0.shipped_at AS date)
  WHERE t0.shipped_at >= DATE '2025-01-01' AND t0.shipped_at < DATE '2026-01-01'
    AND t0.delivered_at IS NOT NULL
  GROUP BY t0.carrier, t1.quarter_start
),
m_median AS (
  SELECT t0.carrier AS carrier, t1.quarter_start AS quarter_start,
    {{percentile_cont(0.5, {{date_diff_days(t0.shipped_at, t0.delivered_at)}})}} AS median_transit_days
  FROM shipments t0
  JOIN calendar_days t1 ON t1.calendar_date = CAST(t0.shipped_at AS date)
  WHERE t0.shipped_at >= DATE '2025-01-01' AND t0.shipped_at < DATE '2026-01-01'
    AND t0.delivered_at IS NOT NULL
  GROUP BY t0.carrier, t1.quarter_start
),
m_within3 AS (
  SELECT t0.carrier AS carrier, t1.quarter_start AS quarter_start,
    COUNT(*) FILTER (WHERE ({{date_diff_days(t0.shipped_at, t0.delivered_at)}}) <= 3) AS delivered_within_3
  FROM shipments t0
  JOIN calendar_days t1 ON t1.calendar_date = CAST(t0.shipped_at AS date)
  WHERE t0.shipped_at >= DATE '2025-01-01' AND t0.shipped_at < DATE '2026-01-01'
    AND t0.delivered_at IS NOT NULL
  GROUP BY t0.carrier, t1.quarter_start
)
SELECT
  g.carrier AS carrier,
  g.year_num || '-Q' || g.quarter_num AS quarter,
  COALESCE(ms.shipments_shipped, 0) AS shipments_shipped,
  COALESCE(md.shipments_delivered, 0) AS shipments_delivered,
  ma.avg_transit_days AS avg_transit_days,
  mm.median_transit_days AS median_transit_days,
  {{divide_decimal(100.0 * COALESCE(mw.delivered_within_3,0), NULLIF(md.shipments_delivered,0))}} AS pct_within_3_days,
  {{divide_decimal(100.0 * COALESCE(md.shipments_delivered,0), NULLIF(ms.shipments_shipped,0))}} AS pct_delivered
FROM grain g
LEFT JOIN m_shipped ms ON ms.carrier = g.carrier AND ms.quarter_start = g.quarter_start
LEFT JOIN m_delivered md ON md.carrier = g.carrier AND md.quarter_start = g.quarter_start
LEFT JOIN m_avg ma ON ma.carrier = g.carrier AND ma.quarter_start = g.quarter_start
LEFT JOIN m_median mm ON mm.carrier = g.carrier AND mm.quarter_start = g.quarter_start
LEFT JOIN m_within3 mw ON mw.carrier = g.carrier AND mw.quarter_start = g.quarter_start
ORDER BY g.carrier ASC NULLS LAST, g.quarter_start ASC NULLS LAST, g.year_num NULLS LAST, g.quarter_num NULLS LAST
