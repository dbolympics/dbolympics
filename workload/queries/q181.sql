WITH scoped AS (
  SELECT
    o.id AS id,
    o.owner_user_id AS owner_user_id,
    o.tenant_id AS tenant_id,
    o.currency_code AS currency_code,
    o.amount AS amount,
    o.is_won AS is_won,
    o.closed_at AS closed_at,
    o.created_at AS created_at,
    t.name AS merchant,
    u.full_name AS rep_name
  FROM opportunities o
  JOIN tenants t ON t.id = o.tenant_id
  JOIN pipelines p ON p.id = o.pipeline_id AND p.tenant_id = o.tenant_id AND p.name = 'New business'
  JOIN users u ON u.id = o.owner_user_id AND u.tenant_id = o.tenant_id
  WHERE t.name IN ('Ballycorran Industrial Supply','Castell Fasteners','Hanse Industriebedarf','Midland Safety Wear','Polder Packaging')
    AND o.is_closed = true
),
rated AS (
  SELECT
    s.*,
    CASE
      WHEN s.currency_code = 'EUR' THEN s.amount
      ELSE {{divide_decimal(s.amount, (
        SELECT er.rate
        FROM exchange_rates er
        WHERE er.base_code = 'EUR'
          AND er.quote_code = s.currency_code
          AND er.as_of <= CAST(s.closed_at AS date)
        ORDER BY er.as_of DESC NULLS FIRST
        {{fetch_first(1)}}
      ))}}
    END AS amount_eur
  FROM scoped s
)
SELECT
  rep_name,
  merchant,
  COUNT(*) AS opportunities_closed,
  COUNT(*) FILTER (WHERE is_won) AS closed_won,
  COUNT(*) FILTER (WHERE NOT is_won) AS closed_lost,
  {{divide_decimal(100.0 * COUNT(*) FILTER (WHERE is_won), COUNT(*))}} AS win_rate_pct,
  AVG({{divide_decimal({{seconds_between(created_at, closed_at)}}, 86400.0)}}) AS avg_days_open,
  AVG(amount_eur) AS avg_amount_eur
FROM rated
GROUP BY owner_user_id, rep_name, merchant
HAVING COUNT(*) >= 3
ORDER BY win_rate_pct ASC NULLS LAST, opportunities_closed DESC NULLS FIRST, rep_name ASC NULLS LAST, owner_user_id ASC NULLS LAST
