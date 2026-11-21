SELECT t.name AS merchant,
  COUNT(*) AS opportunities_closed,
  SUM(CASE WHEN o.is_won THEN 1 ELSE 0 END) AS closed_won,
  SUM(CASE WHEN NOT o.is_won THEN 1 ELSE 0 END) AS closed_lost,
  {{divide_decimal(100.0 * SUM(CASE WHEN o.is_won THEN 1 ELSE 0 END), NULLIF(COUNT(*),0))}} AS win_rate_pct,
  AVG({{divide_decimal({{seconds_between(o.created_at, o.closed_at)}}, 86400.0)}}) AS avg_days_open,
  AVG({{divide_decimal(o.amount, (SELECT er.rate
                   FROM exchange_rates er
                   WHERE er.base_code = 'EUR'
                     AND er.quote_code = o.currency_code
                     AND er.as_of <= CAST(o.closed_at AS date)
                   ORDER BY er.as_of DESC NULLS FIRST
                   {{fetch_first(1)}}))}}) AS avg_amount_eur
FROM opportunities o
JOIN tenants t ON t.id = o.tenant_id
JOIN pipelines p ON p.id = o.pipeline_id AND p.tenant_id = o.tenant_id
WHERE o.is_closed = true
  AND p.name = 'New business'
  AND (t.industry ILIKE '%industrial%' OR t.industry ILIKE '%office equipment%' OR t.industry ILIKE '%wholesal%')
GROUP BY t.id, t.name
ORDER BY win_rate_pct ASC NULLS LAST, opportunities_closed DESC NULLS FIRST, t.name ASC NULLS LAST, t.id ASC NULLS LAST
