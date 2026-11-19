with user_status_stats as (
    select
        status,
        count(*) as total_users,
        count(deleted_at) as users_with_deleted_at,
        max(deleted_at) as most_recent_deleted_at
    from users
    group by status
)
select
    status,
    total_users,
    users_with_deleted_at as count_with_deleted_at_not_null,
    {{divide_decimal(100.0 * users_with_deleted_at, nullif(total_users, 0))}} as pct_with_deleted_at_set,
    most_recent_deleted_at
from user_status_stats
order by total_users desc NULLS FIRST, status asc NULLS LAST
