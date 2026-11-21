with cohort_accounts as (
    select
        la.id as loyalty_account_id,
        la.loyalty_program_id AS loyalty_program_id,
        cd.year_num AS year_num,
        cd.quarter_num AS quarter_num,
        cd.quarter_start AS quarter_start
    from loyalty_accounts la
    join calendar_days cd on cd.calendar_date = cast(la.enrolled_at as date)
    where cd.quarter_start >= date '2023-01-01'
      and cd.quarter_start <= date '2025-10-01'
),

account_currency as (
    select
        ca.loyalty_account_id AS loyalty_account_id,
        ca.year_num AS year_num,
        ca.quarter_num AS quarter_num,
        ca.quarter_start AS quarter_start,
        lp.points_per_currency AS points_per_currency,
        lp.currency_code AS currency_code
    from cohort_accounts ca
    join loyalty_programs lp on lp.id = ca.loyalty_program_id
),

transaction_amounts as (
    select
        ac.loyalty_account_id AS loyalty_account_id,
        ac.year_num AS year_num,
        ac.quarter_num AS quarter_num,
        ac.quarter_start AS quarter_start,
        lt.direction AS direction,
        case
            when ac.currency_code = 'EUR' then ({{divide_decimal(lt.points, ac.points_per_currency)}})
            else CAST(({{divide_decimal(lt.points, ac.points_per_currency)}}) / er.rate AS NUMERIC(18,6))
        end as amount_eur
    from account_currency ac
    join loyalty_transactions lt on lt.loyalty_account_id = ac.loyalty_account_id
    left join exchange_rates er
        on er.base_code = 'EUR'
       and er.quote_code = ac.currency_code
       and er.as_of = cast(lt.occurred_at as date)
),

cohort_members as (
    select
        year_num,
        quarter_num,
        quarter_start,
        count(distinct loyalty_account_id) as member_count
    from cohort_accounts
    group by year_num, quarter_num, quarter_start
),

cohort_transactions as (
    select
        year_num,
        quarter_num,
        quarter_start,
        sum(case when direction = 'earn' then amount_eur else 0 end) as total_points_earned_value_eur,
        sum(case when direction <> 'earn' then amount_eur else 0 end) as total_points_redeemed_value_eur
    from transaction_amounts
    group by year_num, quarter_num, quarter_start
)

select
    cast(cm.year_num as varchar) || '-Q' || cast(cm.quarter_num as varchar) as enrollment_quarter,
    cm.member_count AS member_count,
    (extract(year from date '2025-12-31') - extract(year from cm.quarter_start)) * 12
        + (extract(month from date '2025-12-31') - extract(month from cm.quarter_start))
        as months_since_cohort_quarter_start,
    coalesce(ct.total_points_earned_value_eur, 0) as total_points_earned_value_eur,
    coalesce(ct.total_points_redeemed_value_eur, 0) as total_points_redeemed_value_eur,
    case when coalesce(ct.total_points_earned_value_eur, 0) = 0 then null
         else ct.total_points_redeemed_value_eur / ct.total_points_earned_value_eur * 100
    end as lifetime_redemption_rate_pct
from cohort_members cm
left join cohort_transactions ct
    on ct.year_num = cm.year_num
   and ct.quarter_num = cm.quarter_num
   and ct.quarter_start = cm.quarter_start
order by cm.quarter_start asc NULLS LAST, cm.year_num asc NULLS LAST, cm.quarter_num asc NULLS LAST
