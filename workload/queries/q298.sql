select
  cd.calendar_date as date,
  cd.day_name as day_of_week,
  count(*) as carts_created,
  {{divide_decimal(100.0 * count(*) filter (where c.status = 'converted'), count(*))}} as overall_conversion_pct
from carts c
join tenants t on t.id = c.tenant_id
join calendar_days cd on cd.calendar_date = CAST(c.created_at AS DATE)
where t.name = 'Cragsley Outfitters'
  and cd.calendar_date between date '2025-09-29' and date '2025-11-25'
  and cd.iso_day_of_week in (1, 2)
group by cd.calendar_date, cd.day_name
order by cd.calendar_date asc NULLS LAST
