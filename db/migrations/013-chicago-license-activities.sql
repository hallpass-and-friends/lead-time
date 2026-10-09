-- Two business activities found unmapped in the first full licenses run.
-- Safe to re-run.

INSERT INTO ref.business_activity_map (source_id, activity_raw, business_category_code, priority)
SELECT s.source_id, v.activity_raw, v.category, v.priority
FROM ref.source s
CROSS JOIN (VALUES
  ('Expedited Restaurant without On-Premises Consumption', 'restaurant',  1),
  ('Retail Sales of Live Poultry',                         'food_retail', 2)
) AS v (activity_raw, category, priority)
WHERE s.code = 'chicago-business-licenses'
ON CONFLICT DO NOTHING;
