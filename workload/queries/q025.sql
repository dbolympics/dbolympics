select cd.month_label as month,
       count(*) as orders_delivered,
       avg(cast(dd.delivery_days as numeric(18,6))) as avg_delivery_days,
       {{percentile_cont(0.5, dd.delivery_days)}} as median_delivery_days,
       {{percentile_cont(0.9, dd.delivery_days)}} as p90_delivery_days,
       {{divide_decimal(100.0 * sum(case when dd.delivery_days <= 5 then 1 else 0 end), count(*))}} as pct_within_5_days
from (
  select o.id as order_id,
         o.placed_at AS placed_at,
         {{date_diff_days(o.placed_at, (select max(s.delivered_at)
             from fulfillments f
             join shipments s on s.fulfillment_id = f.id
             where f.order_id = o.id))}} as delivery_days
  from orders o
  where o.status = 'fulfilled'
    and o.placed_at >= timestamp '2024-01-01'
    and o.placed_at < timestamp '2026-01-01'
    and exists (
      select 1 from fulfillments f join shipments s on s.fulfillment_id = f.id where f.order_id = o.id
    )
    and not exists (
      select 1 from fulfillments f join shipments s on s.fulfillment_id = f.id where f.order_id = o.id and s.delivered_at is null
    )
) dd
join calendar_days cd on cd.calendar_date = cast(dd.placed_at as date)
group by cd.month_label
order by cd.month_label NULLS LAST
