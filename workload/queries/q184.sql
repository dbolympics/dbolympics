with cc as (
  select sm.id AS id, sm.variant_id AS variant_id, sm.quantity AS quantity, sm.occurred_at AS occurred_at, sl.warehouse_id AS warehouse_id
  from stock_movements sm
  join stock_locations sl on sl.id = sm.stock_location_id
  where sm.kind = 'cycle_count'
    and sm.occurred_at >= timestamp '2025-01-01'
    and sm.occurred_at < timestamp '2026-01-01'
),
supplier_cost as (
  select variant_id, currency_code, unit_cost
  from (
    select sp.variant_id AS variant_id, sp.currency_code AS currency_code, sp.unit_cost AS unit_cost,
           row_number() over (
             partition by sp.variant_id
             order by case when sp.is_preferred then 0 else 1 end asc NULLS LAST, sp.unit_cost asc NULLS LAST, sp.id asc NULLS LAST
           ) as rn
    from supplier_products sp
    join suppliers s on s.id = sp.supplier_id
    where sp.is_preferred = true or s.is_active = true
  ) t
  where rn = 1
),
valued as (
  select cc.id AS id, cc.variant_id AS variant_id, cc.quantity AS quantity, cc.occurred_at AS occurred_at, cc.warehouse_id AS warehouse_id,
         sc.currency_code AS currency_code, sc.unit_cost AS unit_cost, er.rate AS rate
  from cc
  left join supplier_cost sc on sc.variant_id = cc.variant_id
  left join exchange_rates er
    on er.base_code = 'EUR'
   and er.quote_code = sc.currency_code
   and er.as_of = cast(cc.occurred_at as date)
)
select
  {{year_month(occurred_at)}} as month,
  count(*) as cycle_count_events,
  count(distinct warehouse_id) as warehouses_affected,
  coalesce(sum(abs(quantity)) filter (where quantity < 0), 0) as units_short,
  coalesce(sum(quantity) filter (where quantity > 0), 0) as units_over,
  sum(quantity) as net_units_variance,
  sum(abs(quantity)) as abs_units_variance,
  sum(CAST({{divide_decimal(abs(quantity) * unit_cost, rate)}} AS NUMERIC(18,6))) as estimated_value_eur,
  {{divide_decimal(CAST(sum(abs(quantity)) AS numeric(18,6)), count(*))}} as avg_abs_units_per_event
from valued
group by {{year_month(occurred_at)}}
order by month NULLS LAST
