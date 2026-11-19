WITH published AS (
  SELECT ka.id AS id, ka.title AS title, kc.name AS category_name, ka.view_count AS view_count, ka.helpful_count AS helpful_count, ka.not_helpful_count AS not_helpful_count
  FROM knowledge_articles ka
  LEFT JOIN knowledge_categories kc ON kc.id = ka.knowledge_category_id
  WHERE ka.is_published = true AND ka.deleted_at IS NULL
),
agg AS (
  SELECT COUNT(*) AS total_published_articles,
         SUM(helpful_count) AS total_helpful,
         SUM(helpful_count + not_helpful_count) AS total_votes
  FROM published
)
SELECT
  p.title AS title,
  p.category_name AS knowledge_category_name,
  p.view_count AS view_count,
  p.helpful_count AS helpful_count,
  p.not_helpful_count AS not_helpful_count,
  CASE WHEN (p.helpful_count + p.not_helpful_count) = 0 THEN NULL
       ELSE {{divide_decimal(CAST(p.helpful_count AS numeric(18,6)), (p.helpful_count + p.not_helpful_count))}}
  END AS helpful_rate,
  a.total_published_articles AS total_published_articles,
  {{divide_decimal(CAST(a.total_helpful AS numeric(18,6)), NULLIF(a.total_votes,0))}} AS platform_avg_helpful_rate
FROM published p
CROSS JOIN agg a
ORDER BY p.view_count DESC NULLS FIRST, p.id ASC NULLS LAST
{{fetch_first(20)}}
