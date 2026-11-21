WITH classified AS (
  SELECT o.tenant_id AS tenant_id, o.id as order_id, o.grand_total AS grand_total, o.currency_code AS currency_code, o.placed_at AS placed_at,
         cd.quarter_start AS quarter_start, cd.year_num AS year_num, cd.quarter_num AS quarter_num,
         CASE WHEN t.created_at >= cd.quarter_start AND t.created_at < cd.quarter_start + interval '3 months'
              THEN 'new' ELSE 'existing' END AS cohort,
         CAST({{divide_decimal(o.grand_total, er.rate)}} AS NUMERIC(18,6)) AS amount_eur
  FROM orders o
  JOIN tenants t ON t.id = o.tenant_id
  JOIN calendar_days cd ON cd.calendar_date = CAST(o.placed_at AS date)
  JOIN exchange_rates er ON er.base_code = 'EUR' AND er.quote_code = o.currency_code AND er.as_of = CAST(o.placed_at AS date)
  WHERE o.status IN ('paid','partially_fulfilled','fulfilled','refunded')
    AND cd.quarter_start BETWEEN DATE '2024-01-01' AND DATE '2025-10-01'
),
agg AS (
  SELECT year_num, quarter_num, quarter_start, cohort,
         COUNT(DISTINCT tenant_id) AS merchant_count,
         COUNT(*) AS order_count,
         SUM(amount_eur) AS gmv_eur
  FROM classified
  GROUP BY year_num, quarter_num, quarter_start, cohort
)
SELECT
  year_num || '-Q' || quarter_num AS quarter,
  cohort,
  merchant_count,
  order_count,
  gmv_eur AS gmv_eur,
  {{divide_decimal(100.0 * gmv_eur, SUM(gmv_eur) OVER (PARTITION BY year_num, quarter_num))}} AS share_of_quarter_gmv_pct
FROM agg
ORDER BY year_num NULLS LAST, quarter_num NULLS LAST, (CASE WHEN cohort = 'new' THEN 0 ELSE 1 END) NULLS LAST, quarter_start NULLS LAST
