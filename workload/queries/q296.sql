with target_tenants as (
    select id, name
    from tenants
    where name in ('Kibblewick', 'Studio Vrij', 'Petalcourt Beauty', 'Marrowby & Vane', 'Cragsley Outfitters', 'Ampfeld Elektronik')
),
scoped_carts as (
    select
        c.id AS id,
        c.status AS status,
        case when c.user_id is null then 'guest' else 'logged_in' end as user_status,
        case when c.item_count = 1 then 'single-item' else 'multi-item' end as item_count_group
    from carts c
    join target_tenants t on t.id = c.tenant_id
    where c.created_at >= timestamp '2025-01-01'
      and c.created_at < timestamp '2026-01-01'
      and c.item_count >= 1
),
grouped as (
    select
        user_status,
        item_count_group,
        count(*) as cart_count,
        sum(case when status = 'converted' then 1 else 0 end) as converted_count
    from scoped_carts
    group by user_status, item_count_group
)
select
    user_status,
    item_count_group,
    cart_count,
    {{divide_decimal(100.0 * converted_count, cart_count)}} as conversion_pct
from grouped
order by
    case
        when user_status = 'logged_in' and item_count_group = 'multi-item' then 1
        when user_status = 'logged_in' and item_count_group = 'single-item' then 2
        when user_status = 'guest' and item_count_group = 'multi-item' then 3
        when user_status = 'guest' and item_count_group = 'single-item' then 4
    end NULLS LAST
