SELECT
  tenant_name,
  excluded_period,
  ticket_count_after_exclusion,
  avg_resolution_minutes_after_exclusion,
  resolution_breach_rate_after_exclusion
FROM (
  SELECT
    ft.tenant_name AS tenant_name,
    ft.excluded_period AS excluded_period,
    count(*) AS ticket_count_after_exclusion,
    avg({{divide_decimal({{seconds_between(ft.created_at, ft.resolved_at)}}, 60.0)}}) AS avg_resolution_minutes_after_exclusion,
    {{divide_decimal(100.0 * sum(
      case when exists (
        select 1 from sla_breaches sb
        where sb.ticket_id = ft.ticket_id and sb.breach_kind = 'resolution'
      ) then 1 else 0 end
    ), count(*))}} AS resolution_breach_rate_after_exclusion
  FROM (
    SELECT
      tk.id as ticket_id,
      t.name as tenant_name,
      case
        when t.name = 'Marrowby & Vane' then 'Excludes Nov-Dec 2025'
        when t.name = 'Studio Vrij' then 'Excludes May-Jul 2025'
        else 'None'
      end as excluded_period,
      tk.created_at AS created_at,
      tk.resolved_at AS resolved_at
    FROM tickets tk
    JOIN tenants t ON t.id = tk.tenant_id
    WHERE t.name IN ('Marrowby & Vane', 'Studio Vrij', 'Cragsley Outfitters')
      AND tk.created_at >= timestamp '2025-01-01'
      AND tk.created_at < timestamp '2026-01-01'
      AND NOT (
        (t.name = 'Marrowby & Vane' AND tk.created_at >= timestamp '2025-11-01' AND tk.created_at < timestamp '2026-01-01')
        OR
        (t.name = 'Studio Vrij' AND tk.created_at >= timestamp '2025-05-01' AND tk.created_at < timestamp '2025-08-01')
      )
  ) ft
  GROUP BY ft.tenant_name, ft.excluded_period
) x
ORDER BY resolution_breach_rate_after_exclusion DESC NULLS FIRST, tenant_name NULLS LAST
