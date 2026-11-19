WITH pipelines_filtered AS (
  SELECT p.id AS pipeline_id, p.tenant_id AS tenant_id
  FROM pipelines p
  JOIN tenants t ON t.id = p.tenant_id
  WHERE t.name IN ('Ballycorran Industrial Supply','Castell Fasteners','Hanse Industriebedarf','Midland Safety Wear','Polder Packaging')
    AND p.name = 'New business'
),
opp AS (
  SELECT
    o.id AS id,
    o.is_won AS is_won,
    o.created_at AS created_at,
    o.closed_at AS closed_at,
    CASE WHEN o.currency_code = 'EUR' THEN o.amount
         ELSE {{divide_decimal(o.amount, (
           SELECT er.rate
           FROM exchange_rates er
           WHERE er.base_code = 'EUR'
             AND er.quote_code = o.currency_code
             AND er.as_of <= CAST(o.closed_at AS date)
           ORDER BY er.as_of DESC NULLS FIRST
           {{fetch_first(1)}}
         ))}}
    END AS amount_eur
  FROM opportunities o
  JOIN pipelines_filtered pf ON pf.pipeline_id = o.pipeline_id AND pf.tenant_id = o.tenant_id
  WHERE o.is_closed = true
),
banded AS (
  SELECT
    CASE
      WHEN amount_eur < 3000 THEN '<3000'
      WHEN amount_eur < 6000 THEN '3000-5999'
      WHEN amount_eur < 9000 THEN '6000-8999'
      WHEN amount_eur < 12000 THEN '9000-11999'
      ELSE '12000+'
    END AS amount_band_eur,
    CASE
      WHEN amount_eur < 3000 THEN 1
      WHEN amount_eur < 6000 THEN 2
      WHEN amount_eur < 9000 THEN 3
      WHEN amount_eur < 12000 THEN 4
      ELSE 5
    END AS band_sort,
    is_won,
    closed_at,
    created_at
  FROM opp
)
SELECT
  amount_band_eur,
  COUNT(*) AS opportunities_closed,
  COUNT(*) FILTER (WHERE is_won) AS closed_won,
  COUNT(*) FILTER (WHERE NOT is_won) AS closed_lost,
  {{divide_decimal(100.0 * COUNT(*) FILTER (WHERE is_won), COUNT(*))}} AS win_rate_pct,
  AVG({{divide_decimal({{seconds_between(created_at, closed_at)}}, 86400.0)}}) AS avg_days_open
FROM banded
GROUP BY amount_band_eur, band_sort
ORDER BY band_sort NULLS LAST
