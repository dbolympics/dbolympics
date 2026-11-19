with resolved_tickets_with_csat as (
    select
        t.id as ticket_id,
        c.score as csat_score,
        {{divide_decimal({{seconds_between(t.created_at, t.resolved_at)}}, 3600.0)}} as resolution_hours
    from tickets t
    join csat_responses c
        on c.ticket_id = t.id
    where t.resolved_at is not null
        and t.created_at >= timestamp '2023-01-01'
        and t.created_at < timestamp '2026-01-01'
),
bucketed_tickets as (
    select
        ticket_id,
        csat_score,
        case
            when resolution_hours < 4 then '<4h'
            when resolution_hours < 24 then '4-24h'
            when resolution_hours < 72 then '1-3 days'
            when resolution_hours < 168 then '3-7 days'
            else '>7 days'
        end as resolution_bucket,
        case
            when resolution_hours < 4 then 0
            when resolution_hours < 24 then 4
            when resolution_hours < 72 then 24
            when resolution_hours < 168 then 72
            else 168
        end as bucket_sort_key
    from resolved_tickets_with_csat
),
bucket_summary as (
    select
        resolution_bucket,
        bucket_sort_key,
        count(*) as ticket_count,
        avg(cast(csat_score as numeric(18,6))) as avg_csat_score,
        {{divide_decimal(100.0 * sum(case when csat_score >= 4 then 1 else 0 end), count(*))}} as pct_satisfied,
        {{divide_decimal(100.0 * sum(case when csat_score <= 2 then 1 else 0 end), count(*))}} as pct_dissatisfied
    from bucketed_tickets
    group by resolution_bucket, bucket_sort_key
)
select
    resolution_bucket as resolution_time_bucket,
    ticket_count as tickets,
    avg_csat_score as avg_csat_score,
    pct_satisfied as pct_satisfied,
    pct_dissatisfied as pct_dissatisfied
from bucket_summary
order by bucket_sort_key NULLS LAST
