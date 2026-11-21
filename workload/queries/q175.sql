WITH lost_opps AS (
  SELECT o.id AS id, o.tenant_id AS tenant_id
  FROM opportunities o
  JOIN tenants t ON t.id = o.tenant_id
  JOIN pipelines p ON p.id = o.pipeline_id
  WHERE p.name = 'New business'
    AND o.is_closed = true
    AND o.is_won = false
    AND (t.industry ILIKE '%industrial%' OR t.industry ILIKE '%office equipment%' OR t.industry ILIKE '%wholesal%')
),
last_stage_change AS (
  SELECT entity_id, tenant_id, before_stage_id
  FROM (
    SELECT
      ch.entity_id AS entity_id,
      ch.tenant_id AS tenant_id,
      (JSON_VALUE(ch.before_data, '$.stage_id')) AS before_stage_id,
      ROW_NUMBER() OVER (PARTITION BY ch.entity_id ORDER BY ch.occurred_at DESC NULLS FIRST, ch.id DESC NULLS FIRST) AS rn
    FROM change_history ch
    JOIN lost_opps lo ON lo.id = ch.entity_id AND lo.tenant_id = ch.tenant_id
    WHERE ch.entity_table = 'opportunities'
      AND {{equals_any('stage_id', ch.changed_columns)}}
  ) ranked
  WHERE rn = 1
),
opp_stage AS (
  SELECT
    lo.id AS opportunity_id,
    os.name AS stage_name,
    os.sort_position AS stage_order
  FROM lost_opps lo
  LEFT JOIN last_stage_change lsc ON lsc.entity_id = lo.id
  LEFT JOIN opportunity_stages os ON os.id = CAST(lsc.before_stage_id AS bigint)
)
SELECT
  COALESCE(stage_name, 'No stage transition recorded') AS stage_name,
  stage_order,
  COUNT(*) AS lost_opportunities_last_seen_here,
  {{divide_decimal(100.0 * COUNT(*), SUM(COUNT(*)) OVER ())}} AS pct_of_total_lost_in_new_business,
  SUM(COUNT(*)) OVER () AS total_lost_opportunities_new_business
FROM opp_stage
GROUP BY 1, 2
ORDER BY lost_opportunities_last_seen_here DESC NULLS FIRST, stage_name NULLS LAST
