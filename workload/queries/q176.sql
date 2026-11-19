WITH target_tenants AS (
  SELECT id
  FROM tenants
  WHERE industry ILIKE '%industrial%'
     OR industry ILIKE '%office equipment%'
     OR industry ILIKE '%wholesal%'
),
new_business_pipelines AS (
  SELECT id, tenant_id
  FROM pipelines
  WHERE name = 'New business'
),
base_opportunities AS (
  SELECT o.*
  FROM opportunities o
  JOIN new_business_pipelines p
    ON o.pipeline_id = p.id
   AND o.tenant_id = p.tenant_id
  WHERE o.tenant_id IN (SELECT id FROM target_tenants)
    AND o.is_closed = true
),
opp_with_rate AS (
  SELECT
    bo.*,
    (
      SELECT er.rate
      FROM exchange_rates er
      WHERE er.base_code = 'EUR'
        AND er.quote_code = bo.currency_code
        AND er.as_of <= CAST(bo.closed_at AS DATE)
      ORDER BY er.as_of DESC NULLS FIRST
      {{fetch_first(1)}}
    ) AS eur_rate
  FROM base_opportunities bo
),
activities_before_close AS (
  SELECT
    a.opportunity_id AS opportunity_id,
    count(*) AS activity_count
  FROM activities a
  JOIN base_opportunities bo
    ON a.opportunity_id = bo.id
   AND a.tenant_id = bo.tenant_id
  WHERE a.occurred_at <= bo.closed_at
  GROUP BY a.opportunity_id
),
opp_final AS (
  SELECT
    owr.id AS id,
    owr.account_id AS account_id,
    owr.owner_user_id AS owner_user_id,
    owr.is_won AS is_won,
    CAST({{divide_decimal(owr.amount, owr.eur_rate)}} AS NUMERIC(18,6)) AS amount_eur,
    {{divide_decimal({{seconds_between(owr.created_at, owr.closed_at)}}, 86400.0)}} AS days_open,
    COALESCE(ac.activity_count, 0) AS activity_count
  FROM opp_with_rate owr
  LEFT JOIN activities_before_close ac
    ON ac.opportunity_id = owr.id
)
SELECT
  CASE WHEN is_won THEN 'won' ELSE 'lost' END AS outcome,
  count(*) AS opportunities,
  avg(amount_eur) AS avg_amount_eur,
  {{percentile_cont(0.5, amount_eur)}} AS median_amount_eur,
  avg(cast(activity_count as numeric(18,6))) AS avg_activities_before_close,
  avg(days_open) AS avg_days_open,
  count(DISTINCT account_id) AS distinct_accounts,
  count(DISTINCT owner_user_id) AS distinct_reps
FROM opp_final
GROUP BY is_won
ORDER BY CASE WHEN is_won THEN 0 ELSE 1 END NULLS LAST
