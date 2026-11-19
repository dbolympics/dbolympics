SELECT
  t0.name AS merchant,
  t0.default_currency_code AS currency_code,
  COALESCE(s_counts.opportunities_closed, 0) AS opportunities_closed,
  COALESCE(s_counts.closed_won, 0) AS closed_won,
  COALESCE(s_counts.closed_lost, 0) AS closed_lost,
  {{divide_decimal(COALESCE(s_counts.closed_won, 0) * 100.0, NULLIF(s_counts.opportunities_closed, 0))}} AS win_rate_pct,
  s_days.avg_days_open AS avg_days_open,
  s_amt.avg_amount_eur AS avg_amount_eur
FROM tenants t0
LEFT JOIN (
  SELECT
    o.tenant_id AS tenant_id,
    COUNT(*) AS opportunities_closed,
    SUM(CASE WHEN o.is_won THEN 1 ELSE 0 END) AS closed_won,
    SUM(CASE WHEN NOT o.is_won THEN 1 ELSE 0 END) AS closed_lost
  FROM opportunities o
  JOIN pipelines p ON p.id = o.pipeline_id AND p.tenant_id = o.tenant_id
  WHERE o.is_closed = true
    AND p.name = 'New business'
  GROUP BY o.tenant_id
) s_counts ON s_counts.tenant_id = t0.id
LEFT JOIN (
  SELECT
    o.tenant_id AS tenant_id,
    AVG({{divide_decimal({{seconds_between(o.created_at, o.closed_at)}}, 86400.0)}}) AS avg_days_open
  FROM opportunities o
  JOIN pipelines p ON p.id = o.pipeline_id AND p.tenant_id = o.tenant_id
  WHERE o.is_closed = true
    AND p.name = 'New business'
  GROUP BY o.tenant_id
) s_days ON s_days.tenant_id = t0.id
LEFT JOIN (
  SELECT
    o.tenant_id AS tenant_id,
    AVG(
      CASE
        WHEN o.currency_code = 'EUR' THEN o.amount
        ELSE {{divide_decimal(o.amount, (
          SELECT er.rate
          FROM exchange_rates er
          WHERE er.base_code = 'EUR'
            AND er.quote_code = o.currency_code
            AND er.as_of <= CAST(o.closed_at AS date)
          ORDER BY er.as_of DESC NULLS FIRST
          {{fetch_first(1)}}
        ))}}
      END
    ) AS avg_amount_eur
  FROM opportunities o
  JOIN pipelines p ON p.id = o.pipeline_id AND p.tenant_id = o.tenant_id
  WHERE o.is_closed = true
    AND p.name = 'New business'
  GROUP BY o.tenant_id
) s_amt ON s_amt.tenant_id = t0.id
WHERE t0.name IN ('Ballycorran Industrial Supply','Castell Fasteners','Hanse Industriebedarf','Midland Safety Wear','Polder Packaging')
ORDER BY win_rate_pct ASC NULLS LAST, opportunities_closed DESC NULLS FIRST, merchant ASC NULLS LAST, t0.id NULLS LAST
