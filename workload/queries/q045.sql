select
  {{year_month({{date_trunc('month', submitted_at)}})}} as month,
  count(*) as csat_responses,
  avg(cast(score as numeric(18,6))) as avg_score,
  {{percentile_cont(0.5, score)}} as median_score,
  100.0 * sum(case when score >= 4 then 1 else 0 end) / count(*) as pct_satisfied,
  100.0 * sum(case when score <= 2 then 1 else 0 end) / count(*) as pct_dissatisfied
from csat_responses
where submitted_at >= timestamp '2023-01-01' and submitted_at < timestamp '2026-01-01'
group by {{date_trunc('month', submitted_at)}}
order by month asc NULLS LAST
