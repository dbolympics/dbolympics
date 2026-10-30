WITH months AS (
  SELECT DISTINCT month_label, month_start
  FROM calendar_days
  WHERE calendar_date BETWEEN DATE '2023-01-01' AND DATE '2025-12-31'
),
loyalty_tx AS (
  SELECT
    lt.id AS id,
    lt.direction AS direction,
    lt.occurred_at AS occurred_at,
    lp.currency_code AS currency_code,
    (CAST(lt.points AS numeric(18,6)) / lp.points_per_currency) AS amount_in_currency
  FROM loyalty_transactions lt
  JOIN loyalty_accounts la ON la.id = lt.loyalty_account_id
  JOIN loyalty_programs lp ON lp.id = la.loyalty_program_id
  WHERE lt.occurred_at >= TIMESTAMP '2023-01-01' AND lt.occurred_at < TIMESTAMP '2026-01-01'
),
loyalty_tx_eur AS (
  SELECT
    lt.direction AS direction,
    CAST(lt.amount_in_currency / COALESCE(er.rate, CASE WHEN lt.currency_code = 'EUR' THEN 1 END) AS NUMERIC(18,6)) AS amount_eur,
    CAST({{date_trunc('month', lt.occurred_at)}} AS date) AS month_start
  FROM loyalty_tx lt
  LEFT JOIN exchange_rates er
    ON er.base_code = 'EUR'
    AND er.quote_code = lt.currency_code
    AND er.as_of = CAST(lt.occurred_at AS date)
),
loyalty_monthly AS (
  SELECT
    month_start,
    SUM(CASE WHEN direction = 'earn' THEN ABS(amount_eur) ELSE 0 END) AS earned_value_eur,
    SUM(CASE WHEN direction <> 'earn' THEN ABS(amount_eur) ELSE 0 END) AS redeemed_value_eur
  FROM loyalty_tx_eur
  GROUP BY month_start
),
referral_tx AS (
  SELECT
    rr.redeemed_at AS redeemed_at,
    rr.reward_amount AS reward_amount,
    rr.currency_code AS currency_code
  FROM referral_redemptions rr
  WHERE rr.redeemed_at >= TIMESTAMP '2023-01-01' AND rr.redeemed_at < TIMESTAMP '2026-01-01'
    AND rr.reward_amount IS NOT NULL
),
referral_tx_eur AS (
  SELECT
    CAST(rt.reward_amount / COALESCE(er.rate, CASE WHEN rt.currency_code = 'EUR' THEN 1 END) AS NUMERIC(18,6)) AS amount_eur,
    CAST({{date_trunc('month', rt.redeemed_at)}} AS date) AS month_start
  FROM referral_tx rt
  LEFT JOIN exchange_rates er
    ON er.base_code = 'EUR'
    AND er.quote_code = rt.currency_code
    AND er.as_of = CAST(rt.redeemed_at AS date)
),
referral_monthly AS (
  SELECT
    month_start,
    SUM(amount_eur) AS referral_rewards_paid_eur,
    COUNT(*) AS referral_redemptions_count
  FROM referral_tx_eur
  GROUP BY month_start
),
enrollments_monthly AS (
  SELECT
    CAST({{date_trunc('month', enrolled_at)}} AS date) AS month_start,
    COUNT(*) AS new_enrollments
  FROM loyalty_accounts
  WHERE enrolled_at >= TIMESTAMP '2023-01-01' AND enrolled_at < TIMESTAMP '2026-01-01'
  GROUP BY CAST({{date_trunc('month', enrolled_at)}} AS date)
),
combined AS (
  SELECT
    m.month_label AS month_label,
    m.month_start AS month_start,
    COALESCE(lm.earned_value_eur, 0) AS points_earned_value_eur,
    COALESCE(lm.redeemed_value_eur, 0) AS points_redeemed_value_eur,
    COALESCE(lm.earned_value_eur, 0) - COALESCE(lm.redeemed_value_eur, 0) AS net_points_liability_change_eur,
    COALESCE(rm.referral_rewards_paid_eur, 0) AS referral_rewards_paid_eur,
    COALESCE(rm.referral_redemptions_count, 0) AS referral_redemptions_count,
    COALESCE(em.new_enrollments, 0) AS new_loyalty_enrollments
  FROM months m
  LEFT JOIN loyalty_monthly lm ON lm.month_start = m.month_start
  LEFT JOIN referral_monthly rm ON rm.month_start = m.month_start
  LEFT JOIN enrollments_monthly em ON em.month_start = m.month_start
)
SELECT
  month_label AS month,
  points_earned_value_eur AS points_earned_value_eur,
  points_redeemed_value_eur AS points_redeemed_value_eur,
  net_points_liability_change_eur AS net_points_liability_change_eur,
  SUM(net_points_liability_change_eur) OVER (ORDER BY month_start NULLS LAST, month_label NULLS LAST ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW) AS cumulative_points_liability_eur,
  referral_rewards_paid_eur AS referral_rewards_paid_eur,
  referral_redemptions_count,
  new_loyalty_enrollments
FROM combined
ORDER BY month_start NULLS LAST, month_label NULLS LAST
