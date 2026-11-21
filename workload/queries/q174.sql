WITH b2b_tenants AS (
  SELECT id FROM tenants
  WHERE industry ILIKE '%industrial%' OR industry ILIKE '%office equipment%' OR industry ILIKE '%wholesal%'
),
closed_opps AS (
  SELECT o.id AS id, o.tenant_id AS tenant_id, o.account_id AS account_id, o.owner_user_id AS owner_user_id, o.is_won AS is_won, o.closed_at AS closed_at, o.created_at AS created_at,
    o.amount AS amount,
    o.currency_code AS currency_code,
    CASE WHEN o.currency_code = 'EUR' THEN o.amount
         ELSE {{divide_decimal(o.amount, (
           SELECT er.rate FROM exchange_rates er
           WHERE er.base_code = 'EUR' AND er.quote_code = o.currency_code
             AND er.as_of <= CAST(o.closed_at AS date)
           ORDER BY er.as_of DESC NULLS FIRST {{fetch_first(1)}}
         ))}}
    END AS amount_eur
  FROM opportunities o
  JOIN b2b_tenants t ON t.id = o.tenant_id
  WHERE o.is_closed = true AND o.closed_at IS NOT NULL
),
activity_counts AS (
  SELECT co.id AS opportunity_id, COUNT(a.id) AS activity_count
  FROM closed_opps co
  LEFT JOIN activities a ON a.opportunity_id = co.id AND a.occurred_at <= co.closed_at
  GROUP BY co.id
)
SELECT
  CASE WHEN co.is_won THEN 'won' ELSE 'lost' END AS outcome,
  COUNT(*) AS opportunities,
  AVG(co.amount_eur) AS avg_amount_eur,
  {{percentile_cont(0.5, co.amount_eur)}} AS median_amount_eur,
  AVG(CAST(ac.activity_count AS NUMERIC(18,6))) AS avg_activities_before_close,
  AVG({{divide_decimal({{seconds_between(co.created_at, co.closed_at)}}, 86400.0)}}) AS avg_days_open,
  COUNT(DISTINCT co.account_id) AS distinct_accounts,
  COUNT(DISTINCT co.owner_user_id) AS distinct_reps
FROM closed_opps co
JOIN activity_counts ac ON ac.opportunity_id = co.id
GROUP BY co.is_won
ORDER BY co.is_won DESC NULLS FIRST
