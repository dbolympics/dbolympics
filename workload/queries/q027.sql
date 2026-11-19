with base as (
  select
    o.id as order_id,
    o.placed_at AS placed_at,
    o.status AS status,
    cd.week_start as week_start
  from orders o
  join calendar_days cd on cd.calendar_date = CAST(o.placed_at AS date)
  where o.placed_at >= timestamp '2025-10-01'
    and o.placed_at < timestamp '2026-01-01'
),
fulfillment_agg as (
  select
    f.order_id AS order_id,
    count(s.id) as shipment_count,
    count(s.delivered_at) as delivered_shipment_count,
    max(s.delivered_at) as max_delivered_at
  from fulfillments f
  join shipments s on s.fulfillment_id = f.id
  group by f.order_id
),
combined as (
  select
    b.order_id AS order_id,
    b.placed_at AS placed_at,
    b.status AS status,
    b.week_start AS week_start,
    case
      when fa.shipment_count is not null and fa.shipment_count > 0
           and fa.shipment_count = fa.delivered_shipment_count
      then true else false
    end as is_fully_delivered,
    case
      when fa.shipment_count is not null and fa.shipment_count > 0
           and fa.shipment_count = fa.delivered_shipment_count
      then {{divide_decimal({{seconds_between(b.placed_at, fa.max_delivered_at)}}, 86400.0)}}
      else null
    end as delivery_days
  from base b
  left join fulfillment_agg fa on fa.order_id = b.order_id
)
select
  week_start,
  count(*) as orders_placed,
  count(*) filter (where is_fully_delivered) as orders_delivered,
  avg(delivery_days) filter (where is_fully_delivered) as avg_delivery_days,
  {{divide_decimal(100.0 * count(*) filter (where is_fully_delivered and delivery_days <= 5), nullif(count(*) filter (where is_fully_delivered), 0))}} as pct_within_5_days,
  count(*) filter (where status <> 'fulfilled' or not is_fully_delivered) as orders_still_undelivered
from combined
group by week_start
order by week_start asc NULLS LAST
