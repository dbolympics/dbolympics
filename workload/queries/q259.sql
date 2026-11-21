WITH active_industries AS (
  SELECT DISTINCT t.industry AS industry
  FROM tenants t
  JOIN loyalty_programs lp ON lp.tenant_id = t.id
  WHERE lp.is_active = true AND t.industry IS NOT NULL
),
member_orders AS (
  SELECT o.id AS order_id, o.user_id AS user_id, t.industry AS industry, o.grand_total AS grand_total, o.currency_code AS currency_code, CAST(o.placed_at AS date) AS placed_date
  FROM orders o
  JOIN tenants t ON t.id = o.tenant_id
  JOIN loyalty_accounts la ON la.tenant_id = o.tenant_id AND la.user_id = o.user_id
  WHERE o.placed_at >= DATE '2025-01-01' AND o.placed_at < DATE '2026-01-01'
    AND t.industry IN (SELECT industry FROM active_industries)
),
member_orders_fx AS (
  SELECT mo.*, er.rate AS eur_rate
  FROM member_orders mo
  LEFT JOIN exchange_rates er ON er.base_code = 'EUR' AND er.quote_code = mo.currency_code AND er.as_of = mo.placed_date
),
member_revenue AS (
  SELECT industry, COUNT(DISTINCT user_id) AS members_count,
    SUM(CAST({{divide_decimal(grand_total, eur_rate)}} AS NUMERIC(18,6))) AS member_revenue_eur
  FROM member_orders_fx
  GROUP BY industry
),
redemption_tx AS (
  SELECT t.industry AS industry, {{divide_decimal(lt.points, lp.points_per_currency)}} AS value_local, lp.currency_code AS currency_code, CAST(lt.occurred_at AS date) AS occ_date
  FROM loyalty_transactions lt
  JOIN loyalty_accounts la ON la.id = lt.loyalty_account_id
  JOIN loyalty_programs lp ON lp.id = la.loyalty_program_id
  JOIN tenants t ON t.id = la.tenant_id
  WHERE lt.direction = 'burn'
    AND lt.occurred_at >= DATE '2025-01-01' AND lt.occurred_at < DATE '2026-01-01'
    AND t.industry IN (SELECT industry FROM active_industries)
),
redemption_tx_fx AS (
  SELECT rt.industry AS industry, CAST(rt.value_local / er.rate AS NUMERIC(18,6)) AS value_eur
  FROM redemption_tx rt
  LEFT JOIN exchange_rates er ON er.base_code = 'EUR' AND er.quote_code = rt.currency_code AND er.as_of = rt.occ_date
),
redemption_agg AS (
  SELECT industry, SUM(value_eur) AS points_redeemed_value_eur
  FROM redemption_tx_fx
  GROUP BY industry
),
outstanding AS (
  SELECT t.industry AS industry, {{divide_decimal(la.points_balance, lp.points_per_currency)}} AS value_local, lp.currency_code AS currency_code
  FROM loyalty_accounts la
  JOIN loyalty_programs lp ON lp.id = la.loyalty_program_id
  JOIN tenants t ON t.id = la.tenant_id
  WHERE t.industry IN (SELECT industry FROM active_industries)
),
outstanding_fx AS (
  SELECT o.industry AS industry, CAST(o.value_local / er.rate AS NUMERIC(18,6)) AS value_eur
  FROM outstanding o
  LEFT JOIN exchange_rates er ON er.base_code = 'EUR' AND er.quote_code = o.currency_code AND er.as_of = DATE '2025-12-31'
),
outstanding_agg AS (
  SELECT industry, SUM(value_eur) AS outstanding_points_value_eur
  FROM outstanding_fx
  GROUP BY industry
)
SELECT ai.industry AS industry,
  COALESCE(mr.members_count, 0) AS members_count,
  COALESCE(mr.member_revenue_eur, 0) AS member_revenue_eur,
  COALESCE(ra.points_redeemed_value_eur, 0) AS points_redeemed_value_eur,
  CASE WHEN COALESCE(mr.member_revenue_eur, 0) = 0 THEN NULL ELSE {{divide_decimal(ra.points_redeemed_value_eur, mr.member_revenue_eur)}} * 100 END AS redemption_cost_pct,
  COALESCE(oa.outstanding_points_value_eur, 0) AS outstanding_points_value_eur
FROM active_industries ai
LEFT JOIN member_revenue mr ON mr.industry = ai.industry
LEFT JOIN redemption_agg ra ON ra.industry = ai.industry
LEFT JOIN outstanding_agg oa ON oa.industry = ai.industry
ORDER BY ai.industry NULLS LAST
