-- Site classes from the Resolve profile. The original four (first_time_site,
-- takeover, renewal, unknown) could not express the split that matters most:
-- whether the space was already food. Build-out rates by class in the profile:
-- conversion 47-56%, first_time_site 49%, same_business 41%,
-- food_in_building 26%, food_takeover 16%.
--
--   same_business     the same account was already licensed at the building
--   food_takeover     an earlier food license at the same premises
--   food_in_building  an earlier food license elsewhere in the building (or the
--                     same premises with its address written differently)
--   conversion        only earlier non-food licenses, at the premises or in the building
--   first_time_site   nothing licensed earlier at the building
--
-- Safe to re-run. Refuses to run if any stored row uses a value that is not in
-- the new list, rather than deleting it.

DO $$
BEGIN
  IF EXISTS (
    SELECT 1 FROM resolve.license_site_class
    WHERE site_class NOT IN ('same_business', 'food_takeover', 'food_in_building',
                             'conversion', 'first_time_site')
  ) THEN
    RAISE EXCEPTION 'resolve.license_site_class has rows with an old site class. Delete them (or their match_run) first.';
  END IF;
END $$;

ALTER TABLE resolve.license_site_class
  DROP CONSTRAINT IF EXISTS license_site_class_site_class_check,
  ADD CONSTRAINT license_site_class_site_class_check CHECK (site_class IN (
    'same_business', 'food_takeover', 'food_in_building', 'conversion', 'first_time_site'));
