SELECT
  t.status AS status,
  t.tests_count AS tests_count,
  {{divide_decimal(t.tests_count * 100.0, (SELECT COUNT(*) FROM ab_tests))}} AS share_of_tests_pct,
  t.tests_with_winner_declared_count AS tests_with_winner_declared_count,
  t.avg_variants_per_test AS avg_variants_per_test,
  t.avg_duration_days AS avg_duration_days
FROM (
  SELECT
    a.status AS status,
    COUNT(*) AS tests_count,
    COUNT(*) FILTER (WHERE a.winner_variant_id IS NOT NULL) AS tests_with_winner_declared_count,
    AVG(CAST(vc.variant_count AS NUMERIC(18,6))) AS avg_variants_per_test,
    AVG(CASE WHEN a.started_at IS NOT NULL AND a.ended_at IS NOT NULL
         THEN {{divide_decimal({{seconds_between(a.started_at, a.ended_at)}}, 86400.0)}} END) AS avg_duration_days
  FROM ab_tests a
  LEFT JOIN (
    SELECT ab_test_id, COUNT(*) AS variant_count
    FROM ab_variants
    GROUP BY ab_test_id
  ) vc ON vc.ab_test_id = a.id
  GROUP BY a.status
) t
ORDER BY t.tests_count DESC NULLS FIRST, t.status ASC NULLS LAST
