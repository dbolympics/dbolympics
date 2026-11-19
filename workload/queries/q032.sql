SELECT
  a.month AS month,
  a.shipments_shipped AS shipments_shipped,
  COALESCE(b.shipments_delivered, 0) AS shipments_delivered,
  b.avg_transit_days AS avg_transit_days,
  b.median_transit_days AS median_transit_days,
  b.p90_transit_days AS p90_transit_days,
  b.pct_within_3_days AS pct_within_3_days,
  {{divide_decimal(100.0 * COALESCE(b.shipments_delivered, 0), a.shipments_shipped)}} AS pct_delivered
FROM (
  SELECT cd.month_label AS month, COUNT(*) AS shipments_shipped
  FROM shipments s
  JOIN calendar_days cd ON cd.calendar_date = CAST(s.shipped_at AS date)
  WHERE s.carrier = 'Albion Parcel'
    AND s.shipped_at >= DATE '2025-01-01'
    AND s.shipped_at < DATE '2026-01-01'
  GROUP BY cd.month_label
) a
LEFT JOIN (
  SELECT
    cd.month_label AS month,
    COUNT(*) AS shipments_delivered,
    AVG({{divide_decimal({{seconds_between(s.shipped_at, s.delivered_at)}}, 86400.0)}}) AS avg_transit_days,
    {{percentile_cont(0.5, {{divide_decimal({{seconds_between(s.shipped_at, s.delivered_at)}}, 86400.0)}})}} AS median_transit_days,
    {{percentile_cont(0.9, {{divide_decimal({{seconds_between(s.shipped_at, s.delivered_at)}}, 86400.0)}})}} AS p90_transit_days,
    {{divide_decimal(100.0 * SUM(CASE WHEN {{divide_decimal({{seconds_between(s.shipped_at, s.delivered_at)}}, 86400.0)}} <= 3 THEN 1 ELSE 0 END), COUNT(*))}} AS pct_within_3_days
  FROM shipments s
  JOIN calendar_days cd ON cd.calendar_date = CAST(s.shipped_at AS date)
  WHERE s.carrier = 'Albion Parcel'
    AND s.shipped_at >= DATE '2025-01-01'
    AND s.shipped_at < DATE '2026-01-01'
    AND s.delivered_at IS NOT NULL
  GROUP BY cd.month_label
) b ON a.month = b.month
ORDER BY a.month ASC NULLS LAST
