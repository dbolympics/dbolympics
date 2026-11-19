SELECT
  CASE WHEN m.is_ever_redeemed THEN 'ever-redeemed member' ELSE 'never-redeemed member' END AS "group",
  COUNT(*) AS member_count,
  SUM(m.revenue_eur) AS total_revenue_eur,
  {{divide_decimal(SUM(m.revenue_eur), COUNT(*))}} AS revenue_per_customer_eur,
  SUM(m.redeemed_cost_eur) AS total_points_redeemed_cost_eur,
  SUM(m.earned_liability_eur) AS total_points_earned_liability_eur,
  CASE WHEN SUM(m.revenue_eur) = 0 THEN NULL ELSE SUM(m.redeemed_cost_eur) / SUM(m.revenue_eur) * 100 END AS redeemed_cost_pct_of_revenue
FROM (
  SELECT
    u.id AS user_id,
    EXISTS (SELECT 1 FROM loyalty_transactions lt WHERE lt.user_id = u.id AND lt.direction = 'burn') AS is_ever_redeemed,
    (SELECT COALESCE(SUM(
        CASE WHEN o.currency_code = 'EUR' THEN o.grand_total
             ELSE CAST({{divide_decimal(o.grand_total, er.rate)}} AS NUMERIC(18,6)) END
      ), 0)
     FROM orders o
     LEFT JOIN exchange_rates er ON er.base_code = 'EUR' AND er.quote_code = o.currency_code AND er.as_of = CAST(o.placed_at AS DATE)
     WHERE o.user_id = u.id
       AND o.status <> 'cancelled'
       AND o.placed_at >= DATE '2023-01-01' AND o.placed_at < DATE '2026-01-01'
    ) AS revenue_eur,
    (SELECT COALESCE(SUM(
        CASE WHEN lp.currency_code = 'EUR' THEN {{divide_decimal(ABS(lt2.points), lp.points_per_currency)}}
             ELSE CAST(({{divide_decimal(ABS(lt2.points), lp.points_per_currency)}}) / er2.rate AS NUMERIC(18,6)) END
      ), 0)
     FROM loyalty_transactions lt2
     JOIN loyalty_accounts la2 ON la2.id = lt2.loyalty_account_id
     JOIN loyalty_programs lp ON lp.id = la2.loyalty_program_id
     LEFT JOIN exchange_rates er2 ON er2.base_code = 'EUR' AND er2.quote_code = lp.currency_code AND er2.as_of = CAST(lt2.occurred_at AS DATE)
     WHERE lt2.user_id = u.id AND lt2.direction = 'burn'
    ) AS redeemed_cost_eur,
    (SELECT COALESCE(SUM(
        CASE WHEN lp.currency_code = 'EUR' THEN {{divide_decimal(ABS(lt3.points), lp.points_per_currency)}}
             ELSE CAST(({{divide_decimal(ABS(lt3.points), lp.points_per_currency)}}) / er3.rate AS NUMERIC(18,6)) END
      ), 0)
     FROM loyalty_transactions lt3
     JOIN loyalty_accounts la3 ON la3.id = lt3.loyalty_account_id
     JOIN loyalty_programs lp ON lp.id = la3.loyalty_program_id
     LEFT JOIN exchange_rates er3 ON er3.base_code = 'EUR' AND er3.quote_code = lp.currency_code AND er3.as_of = CAST(lt3.occurred_at AS DATE)
     WHERE lt3.user_id = u.id AND lt3.direction = 'earn'
    ) AS earned_liability_eur
  FROM users u
  WHERE EXISTS (SELECT 1 FROM loyalty_accounts la WHERE la.user_id = u.id)
    AND EXISTS (SELECT 1 FROM orders o2 WHERE o2.user_id = u.id AND o2.placed_at >= DATE '2023-01-01' AND o2.placed_at < DATE '2026-01-01')
) m
GROUP BY m.is_ever_redeemed
ORDER BY m.is_ever_redeemed DESC NULLS FIRST
