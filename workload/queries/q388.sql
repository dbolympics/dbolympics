WITH opp AS (
  SELECT
    o.tenant_id AS tenant_id,
    t.name AS merchant,
    o.amount AS amount,
    o.currency_code AS currency_code,
    o.closed_at AS closed_at,
    os.is_won AS is_won,
    os.is_lost AS is_lost
  FROM opportunities o
  JOIN tenants t ON t.id = o.tenant_id
  JOIN pipelines p ON p.id = o.pipeline_id AND p.tenant_id = o.tenant_id
  JOIN opportunity_stages os ON os.id = o.stage_id
  WHERE t.name IN (
    'Ballycorran Industrial Supply','Castell Fasteners','Hanse Industriebedarf',
    'Midland Safety Wear','Polder Packaging'
  )
  AND p.name = 'New business'
  AND o.is_closed = true
),
rated AS (
  SELECT
    opp.merchant AS merchant,
    opp.is_won AS is_won,
    opp.is_lost AS is_lost,
    CASE
      WHEN opp.currency_code = 'EUR' THEN opp.amount
      ELSE {{divide_decimal(opp.amount, (
        SELECT er.rate
        FROM exchange_rates er
        WHERE er.base_code = 'EUR'
          AND er.quote_code = opp.currency_code
          AND er.as_of <= CAST(opp.closed_at AS date)
        ORDER BY er.as_of DESC NULLS FIRST
        {{fetch_first(1)}}
      ))}}
    END AS amount_eur
  FROM opp
),
agg AS (
  SELECT
    merchant,
    COUNT(*) AS opportunities_closed,
    SUM(CASE WHEN is_won THEN 1 ELSE 0 END) AS won_count,
    SUM(CASE WHEN is_won THEN amount_eur ELSE 0 END) AS total_amount_won_eur,
    SUM(CASE WHEN is_lost THEN amount_eur ELSE 0 END) AS total_amount_lost_eur
  FROM rated
  GROUP BY merchant
)
SELECT
  merchant,
  opportunities_closed,
  {{divide_decimal(100.0 * won_count, opportunities_closed)}} AS count_win_rate_pct,
  total_amount_won_eur AS total_amount_won_eur,
  total_amount_lost_eur AS total_amount_lost_eur,
  100.0 * total_amount_won_eur / NULLIF(total_amount_won_eur + total_amount_lost_eur, 0) AS dollar_weighted_win_rate_pct,
  ({{divide_decimal(100.0 * won_count, opportunities_closed)}})
  - (100.0 * total_amount_won_eur / NULLIF(total_amount_won_eur + total_amount_lost_eur, 0)) AS gap_pct_points
FROM agg
ORDER BY gap_pct_points DESC NULLS FIRST, merchant ASC NULLS LAST
