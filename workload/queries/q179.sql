SELECT
  u.full_name AS rep_name,
  t.name AS merchant,
  COUNT(*) AS opportunities_closed,
  SUM(CASE WHEN o.is_won THEN 1 ELSE 0 END) AS closed_won,
  SUM(CASE WHEN NOT o.is_won THEN 1 ELSE 0 END) AS closed_lost,
  {{divide_decimal(100.0 * SUM(CASE WHEN o.is_won THEN 1 ELSE 0 END), COUNT(*))}} AS win_rate_pct,
  AVG({{divide_decimal({{seconds_between(o.created_at, o.closed_at)}}, 86400.0)}}) AS avg_days_open,
  AVG(
CASE WHEN o.currency_code = 'EUR' THEN o.amount
ELSE {{divide_decimal(o.amount, (
SELECT er.rate
FROM exchange_rates er
WHERE er.base_code = 'EUR'
  AND er.quote_code = o.currency_code
  AND er.as_of = CAST(o.closed_at AS date)
))}} END
) AS avg_amount_eur
FROM opportunities o
JOIN users u ON u.id = o.owner_user_id
JOIN tenants t ON t.id = o.tenant_id
JOIN pipelines pl ON pl.id = o.pipeline_id AND pl.tenant_id = o.tenant_id
WHERE o.is_closed = true
  AND pl.name = 'New business'
  AND o.tenant_id IN (
    SELECT tn.id AS id FROM tenants tn WHERE tn.industry IN ('industrial supplies', 'office equipment')
  )
GROUP BY o.owner_user_id, u.full_name, t.name
HAVING COUNT(*) >= 3
ORDER BY win_rate_pct ASC NULLS LAST, opportunities_closed DESC NULLS FIRST, rep_name ASC NULLS LAST
