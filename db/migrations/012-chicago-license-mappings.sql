-- Chicago's license vocabulary, mapped onto the common business categories.
-- Safe to re-run: existing rows are left alone.

-- A food license whose business activity does not say what kind of food business it is.
INSERT INTO ref.business_category (code, name) VALUES
  ('food_unclassified', 'Food business of unknown kind')
ON CONFLICT (code) DO NOTHING;

-- The license type decides the family of business. Only the Retail Food license
-- is refined further, by its business activities (below).
INSERT INTO ref.license_type_map (source_id, license_type_raw, business_category_code)
SELECT s.source_id, v.license_type_raw, v.category
FROM ref.source s
CROSS JOIN (VALUES
  ('Retail Food Establishment',                     'food_unclassified'),
  ('Tavern',                                        'bar'),
  ('Consumption on Premises - Incidental Activity', 'liquor'),
  ('Package Goods',                                 'liquor'),
  ('Caterer''s Liquor License',                     'liquor')
) AS v (license_type_raw, category)
WHERE s.code = 'chicago-business-licenses'
ON CONFLICT DO NOTHING;

-- Business activities for Retail Food licenses. When a license lists several,
-- the lowest priority number wins: dining beats groceries, groceries beat coffee,
-- and general merchandise only counts when nothing else is listed.
INSERT INTO ref.business_activity_map (source_id, activity_raw, business_category_code, priority)
SELECT s.source_id, v.activity_raw, v.category, v.priority
FROM ref.source s
CROSS JOIN (VALUES
  ('Preparation of Food and Dining on Premises With Seating',                     'restaurant',  1),
  ('Sale of Food Prepared Onsite With Dining Area',                               'restaurant',  1),
  ('Sale of Food Prepared Onsite Without Dining Area',                            'restaurant',  1),
  ('Expedited Restaurant with On-Premises Consumption',                           'restaurant',  1),
  ('Retail Sales of Perishable Foods',                                            'food_retail', 2),
  ('Operation of a Deli, Butcher or Bakery',                                      'food_retail', 2),
  ('Retail Sales of Fresh Fruits and Vegetables (Leafy and Non Leafy Vegetables)', 'food_retail', 2),
  ('Retail Sale of Food for Offsite Consumption',                                 'food_retail', 2),
  ('Retail Sales and Wholesale of Perishable Foods',                              'food_retail', 2),
  ('Preparation and Sale of Coffee and/or Drinks',                                'restaurant',  3),
  ('Preparation of Food, Coffee or Drinks',                                       'restaurant',  3),
  ('Retail Sales of General Merchandise and Non-Perishable Food',                 'food_retail', 4),
  ('Retail Sales of General Merchandise',                                         'food_retail', 4)
) AS v (activity_raw, category, priority)
WHERE s.code = 'chicago-business-licenses'
ON CONFLICT DO NOTHING;

-- Seen once in the permits transform report.
INSERT INTO ref.contact_type_map (source_id, contact_type_raw, role_code, trade)
SELECT s.source_id, 'CONTRACTOR-HEATING', 'contractor', 'heating'
FROM ref.source s
WHERE s.code = 'chicago-building-permits'
ON CONFLICT DO NOTHING;
