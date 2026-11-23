with tenant_scope as (
    select id as tenant_id, name
    from tenants
    where name in ('Ballycorran Industrial Supply','Castell Fasteners','Hanse Industriebedarf','Midland Safety Wear','Polder Packaging')
),
pipeline_scope as (
    select p.id as pipeline_id, p.tenant_id AS tenant_id
    from pipelines p
    join tenant_scope t on p.tenant_id = t.tenant_id
    where p.name = 'New business'
),
lost_opportunities as (
    select
        o.id as opportunity_id,
        o.created_at AS created_at,
        o.closed_at AS closed_at,
        ({{divide_decimal({{seconds_between(o.created_at, o.closed_at)}}, 86400.0)}}) as days_open
    from opportunities o
    join pipeline_scope ps
        on o.pipeline_id = ps.pipeline_id
        and o.tenant_id = ps.tenant_id
    where o.is_closed = true
      and o.is_won = false
      and o.closed_at is not null
),
dated as (
    select
        lo.opportunity_id AS opportunity_id,
        lo.days_open AS days_open,
        cd.year_num AS year_num,
        cd.quarter_num AS quarter_num
    from lost_opportunities lo
    join calendar_days cd on cd.calendar_date = CAST(lo.closed_at AS date)
)
select
    (year_num || 'Q' || quarter_num) as quarter,
    count(*) as lost_opportunities_count,
    avg(days_open) as avg_days_open,
    {{percentile_cont(0.5, days_open)}} as median_days_open
from dated
group by year_num, quarter_num
order by year_num NULLS LAST, quarter_num NULLS LAST
