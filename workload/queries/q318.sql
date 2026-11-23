with shoppers as (
    select id, tenant_id, email
    from users
    where is_staff = false
      and deleted_at is null
),
oauth_linked_users as (
    select distinct user_id
    from oauth_accounts
),
confirmed_mfa_users as (
    select distinct user_id
    from mfa_devices
    where confirmed_at is not null
),
recent_login_users as (
    select distinct s.id as user_id
    from shoppers s
    join login_attempts la
      on la.tenant_id = s.tenant_id
     and (la.user_id = s.id or la.email = s.email)
    where la.occurred_at >= timestamp '2025-10-05'
      and la.occurred_at <  timestamp '2026-01-01'
),
classified_shoppers as (
    select
        s.id AS id,
        case when o.user_id is not null then 'OAuth-linked' else 'password-only' end as method_category
    from shoppers s
    left join oauth_linked_users o on o.user_id = s.id
),
total_shoppers as (
    select count(*) as total_count from shoppers
)
select
    cs.method_category AS method_category,
    count(*) as shopper_user_count,
    {{divide_decimal(100.0 * count(*), t.total_count)}} as share_of_shoppers_pct,
    count(mfa.user_id) as confirmed_mfa_count,
    count(rl.user_id) as recently_active_count
from classified_shoppers cs
cross join total_shoppers t
left join confirmed_mfa_users mfa on mfa.user_id = cs.id
left join recent_login_users rl on rl.user_id = cs.id
group by cs.method_category, t.total_count
order by shopper_user_count desc NULLS FIRST, cs.method_category NULLS LAST
