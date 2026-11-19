SELECT
  t.name AS tenant_name,
  base.delivery_bucket AS delivery_bucket,
  count(*) AS shipments_count,
  {{divide_decimal(100.0 * count(distinct case when exists (
      select 1 from order_returns orr where orr.order_id = base.order_id
    ) then base.order_id end), nullif(count(distinct base.order_id), 0))}} AS pct_orders_with_return
FROM (
  select o.tenant_id AS tenant_id, o.id as order_id,
    case when (s.delivered_at - s.shipped_at) <= interval '7 days' then 'on-time' else 'late' end as delivery_bucket
  from shipments s
  join fulfillments f on f.id = s.fulfillment_id
  join orders o on o.id = f.order_id
  where s.shipped_at >= timestamp '2025-10-01'
    and s.shipped_at < timestamp '2026-01-01'
    and s.delivered_at is not null
) base
join tenants t on t.id = base.tenant_id
where t.name in ('Marrowby & Vane', 'Studio Vrij', 'Cragsley Outfitters')
group by t.name, base.delivery_bucket
order by t.name NULLS LAST, (case when base.delivery_bucket = 'on-time' then 0 else 1 end) NULLS LAST
