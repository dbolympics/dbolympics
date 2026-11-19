with tenant as (
  select id as tenant_id
  from tenants
  where name = 'Cragsley Outfitters'
),
cart_weeks as (
  select
    c.id AS id,
    c.status AS status,
    c.created_at AS created_at,
    c.converted_at AS converted_at,
    cd.week_start AS week_start
  from carts c
  join tenant t on c.tenant_id = t.tenant_id
  join calendar_days cd on cd.calendar_date = CAST(c.created_at AS date)
  where cd.week_start >= date '2025-10-06'
    and cd.week_start <= date '2025-12-22'
)
select
  week_start,
  count(*) as carts_created,
  {{divide_decimal(100.0 * sum(case when status = 'converted' then 1 else 0 end), count(*))}} as overall_conversion_pct,
  {{divide_decimal(100.0 * sum(case when status = 'converted' and converted_at is not null
      and {{divide_decimal({{seconds_between(created_at, converted_at)}}, 3600.0)}} <= 1
      then 1 else 0 end), count(*))}} as pct_converted_within_1_hour,
  {{divide_decimal(100.0 * sum(case when status = 'converted' and converted_at is not null
      and {{divide_decimal({{seconds_between(created_at, converted_at)}}, 3600.0)}} >= 24
      and {{divide_decimal({{seconds_between(created_at, converted_at)}}, 3600.0)}} <= 168
      then 1 else 0 end), count(*))}} as pct_converted_1_to_7_days
from cart_weeks
group by week_start
order by week_start asc NULLS LAST
