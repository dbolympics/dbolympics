WITH population AS (
  SELECT DISTINCT u.id AS user_id, u.tenant_id AS tenant_id
  FROM users u
  JOIN orders o
    ON o.tenant_id = u.tenant_id
   AND o.user_id = u.id
  WHERE u.is_staff = false
    AND o.placed_at >= DATE '2023-01-01'
    AND o.placed_at <  DATE '2026-01-01'
),
segment_membership AS (
  SELECT
    p.user_id AS user_id,
    p.tenant_id AS tenant_id,
    CASE WHEN la.user_id IS NOT NULL THEN 'loyalty member' ELSE 'non-member' END AS segment
  FROM population p
  LEFT JOIN (SELECT DISTINCT tenant_id, user_id FROM loyalty_accounts) la
    ON la.tenant_id = p.tenant_id AND la.user_id = p.user_id
),
revenue_detail AS (
  SELECT
    sm.segment AS segment,
    CAST({{divide_decimal(o.grand_total, COALESCE(er.rate, CASE WHEN o.currency_code = 'EUR' THEN 1 END))}} AS NUMERIC(18,6)) AS revenue_eur
  FROM segment_membership sm
  JOIN orders o
    ON o.tenant_id = sm.tenant_id AND o.user_id = sm.user_id
  LEFT JOIN exchange_rates er
    ON er.base_code = 'EUR'
   AND er.quote_code = o.currency_code
   AND er.as_of = CAST(o.placed_at AS date)
  WHERE o.status <> 'cancelled'
),
loyalty_tx_detail AS (
  SELECT
    sm.segment AS segment,
    lt.direction AS direction,
    CAST({{divide_decimal(ABS(lt.points), lp.points_per_currency)}}
      / COALESCE(er.rate, CASE WHEN lp.currency_code = 'EUR' THEN 1 END) AS NUMERIC(18,6)) AS points_value_eur
  FROM segment_membership sm
  JOIN loyalty_accounts la
    ON la.tenant_id = sm.tenant_id AND la.user_id = sm.user_id
  JOIN loyalty_transactions lt
    ON lt.tenant_id = la.tenant_id AND lt.loyalty_account_id = la.id
  JOIN loyalty_programs lp
    ON lp.tenant_id = la.tenant_id AND lp.id = la.loyalty_program_id
  LEFT JOIN exchange_rates er
    ON er.base_code = 'EUR'
   AND er.quote_code = lp.currency_code
   AND er.as_of = CAST(lt.occurred_at AS date)
),
customer_counts AS (
  SELECT segment, COUNT(*) AS customer_count
  FROM segment_membership
  GROUP BY segment
),
revenue_totals AS (
  SELECT segment, SUM(revenue_eur) AS total_revenue_eur
  FROM revenue_detail
  GROUP BY segment
),
redeemed_totals AS (
  SELECT segment, SUM(points_value_eur) AS total_redeemed_eur
  FROM loyalty_tx_detail
  WHERE direction <> 'earn'
  GROUP BY segment
),
earned_totals AS (
  SELECT segment, SUM(points_value_eur) AS total_earned_eur
  FROM loyalty_tx_detail
  WHERE direction = 'earn'
  GROUP BY segment
)
SELECT
  cc.segment AS segment,
  cc.customer_count AS customer_count,
  COALESCE(rev.total_revenue_eur, 0) AS total_revenue_eur,
  {{divide_decimal(COALESCE(rev.total_revenue_eur, 0), cc.customer_count)}} AS revenue_per_customer_eur,
  COALESCE(red.total_redeemed_eur, 0) AS total_points_redeemed_cost_eur,
  {{divide_decimal(COALESCE(red.total_redeemed_eur, 0), cc.customer_count)}} AS redeemed_cost_per_customer_eur,
  COALESCE(earn.total_earned_eur, 0) AS total_points_earned_liability_eur,
  {{divide_decimal(COALESCE(earn.total_earned_eur, 0), cc.customer_count)}} AS earned_liability_per_customer_eur,
  {{divide_decimal(100.0 * COALESCE(red.total_redeemed_eur, 0), NULLIF(COALESCE(rev.total_revenue_eur, 0), 0))}} AS redeemed_cost_pct_of_revenue
FROM customer_counts cc
LEFT JOIN revenue_totals rev ON rev.segment = cc.segment
LEFT JOIN redeemed_totals red ON red.segment = cc.segment
LEFT JOIN earned_totals earn ON earn.segment = cc.segment
ORDER BY CASE WHEN cc.segment = 'loyalty member' THEN 0 ELSE 1 END NULLS LAST, cc.segment NULLS LAST
