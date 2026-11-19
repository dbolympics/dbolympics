SELECT
  u.full_name AS rep_name,
  t.name AS merchant,
  COUNT(*) AS opportunities_closed,
  {{divide_decimal(100.0 * SUM(CASE WHEN sub.is_won THEN 1 ELSE 0 END), COUNT(*))}} AS count_win_rate_pct,
  SUM(CASE WHEN sub.is_won THEN sub.amount_eur ELSE 0 END) AS total_amount_won_eur,
  SUM(CASE WHEN NOT sub.is_won THEN sub.amount_eur ELSE 0 END) AS total_amount_lost_eur,
  100.0 * SUM(CASE WHEN sub.is_won THEN sub.amount_eur ELSE 0 END) / NULLIF(SUM(sub.amount_eur), 0) AS dollar_weighted_win_rate_pct,
  ({{divide_decimal(100.0 * SUM(CASE WHEN sub.is_won THEN 1 ELSE 0 END), COUNT(*))}})
  - (100.0 * SUM(CASE WHEN sub.is_won THEN sub.amount_eur ELSE 0 END) / NULLIF(SUM(sub.amount_eur), 0)) AS gap_pct_points
FROM (
  SELECT
    o.tenant_id AS tenant_id,
    o.owner_user_id AS owner_user_id,
    o.is_won AS is_won,
    CASE
      WHEN o.currency_code = 'EUR' THEN o.amount
      ELSE {{divide_decimal(o.amount, (
        SELECT er.rate
        FROM exchange_rates er
        WHERE er.base_code = 'EUR'
          AND er.quote_code = o.currency_code
          AND er.as_of <= CAST(o.closed_at AS DATE)
        ORDER BY er.as_of DESC NULLS FIRST
        {{fetch_first(1)}}
      ))}}
    END AS amount_eur
  FROM opportunities o
  JOIN tenants t2 ON t2.id = o.tenant_id
  JOIN pipelines p ON p.id = o.pipeline_id
  WHERE t2.name IN (
      'Ballycorran Industrial Supply',
      'Castell Fasteners',
      'Hanse Industriebedarf',
      'Midland Safety Wear',
      'Polder Packaging'
    )
    AND p.name = 'New business'
    AND o.is_closed = true
) sub
JOIN users u ON u.id = sub.owner_user_id
JOIN tenants t ON t.id = sub.tenant_id
GROUP BY sub.owner_user_id, u.full_name, t.name
HAVING COUNT(*) >= 3
ORDER BY gap_pct_points DESC NULLS FIRST, rep_name ASC NULLS LAST, sub.owner_user_id NULLS LAST, t.name NULLS LAST
