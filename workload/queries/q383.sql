WITH polder_tenant AS (
  SELECT id AS tenant_id
  FROM tenants
  WHERE name = 'Polder Packaging'
),
owner AS (
  SELECT u.id AS user_id
  FROM users u
  JOIN polder_tenant pt ON u.tenant_id = pt.tenant_id
  WHERE u.full_name = 'Youssef Meijer'
),
pipeline AS (
  SELECT p.id AS pipeline_id
  FROM pipelines p
  JOIN polder_tenant pt ON p.tenant_id = pt.tenant_id
  WHERE p.name = 'New business'
),
target_opportunities AS (
  SELECT
    o.id AS id,
    o.account_id AS account_id,
    o.amount AS amount,
    o.currency_code AS currency_code,
    o.is_won AS is_won,
    o.created_at AS created_at,
    o.closed_at AS closed_at
  FROM opportunities o
  JOIN owner ON o.owner_user_id = owner.user_id
  JOIN pipeline ON o.pipeline_id = pipeline.pipeline_id
  WHERE o.is_closed = true
),
with_account AS (
  SELECT
    t.*,
    a.name AS account_name
  FROM target_opportunities t
  JOIN accounts a ON t.account_id = a.id
),
with_rate AS (
  SELECT
    wa.*,
    CASE
      WHEN wa.currency_code = 'EUR' THEN 1.0
      ELSE (
        SELECT er.rate
        FROM exchange_rates er
        WHERE er.base_code = 'EUR'
          AND er.quote_code = wa.currency_code
          AND er.as_of <= CAST(wa.closed_at AS date)
        ORDER BY er.as_of DESC NULLS FIRST
        {{fetch_first(1)}}
      )
    END AS eur_rate
  FROM with_account wa
)
SELECT
  account_name,
  CASE WHEN is_won THEN 'won' ELSE 'lost' END AS outcome,
  CAST({{divide_decimal(amount, eur_rate)}} AS NUMERIC(18,6)) AS amount_eur,
  currency_code,
  {{date_diff_days(created_at, closed_at)}} AS days_open,
  created_at,
  closed_at
FROM with_rate
ORDER BY closed_at ASC NULLS LAST, account_name ASC NULLS LAST, id ASC NULLS LAST
