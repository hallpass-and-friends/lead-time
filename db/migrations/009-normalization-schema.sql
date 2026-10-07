-- Schema changes for normalization, based on profiling the loaded raw data
-- (db/profiling). Run once. Assumes core is still empty.

DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM core.address) THEN
    RAISE EXCEPTION 'core.address has rows. This migration reshapes it and expects it empty.';
  END IF;
END $$;

-- ---------------------------------------------------------------------------
-- Street list
-- ---------------------------------------------------------------------------

-- Known streets, built from sources that give the street as a clean separate
-- field. Free-text addresses are parsed by finding the longest known street in
-- them, which works where a list of street types does not (FULTON MARKET,
-- AVENUE O, BROADWAY).
CREATE TABLE core.street (
  street_id       integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  jurisdiction_id smallint NOT NULL REFERENCES ref.jurisdiction,
  -- Null for cities that do not use a leading direction.
  pre_direction   text,
  name            text NOT NULL,
  UNIQUE NULLS NOT DISTINCT (jurisdiction_id, pre_direction, name),
  CHECK (name = upper(btrim(name)))
);

-- ---------------------------------------------------------------------------
-- Address
-- ---------------------------------------------------------------------------

-- street_name now holds the whole name ("DIVERSEY AVE"), so the separate type
-- and trailing-direction columns go. floor is added because the text after the
-- street is usually a floor, sometimes a suite, often both, and they must not
-- be confused: "1" as a floor and "1" as a suite are different places.
ALTER TABLE core.address
  DROP COLUMN full_key,
  DROP COLUMN base_key,
  DROP COLUMN street_type,
  DROP COLUMN post_direction;

ALTER TABLE core.address
  ADD COLUMN floor text,
  ADD COLUMN base_key text GENERATED ALWAYS AS (
    house_number::text
    || coalesce(' ' || pre_direction, '')
    || ' ' || street_name
  ) STORED,
  ADD COLUMN full_key text GENERATED ALWAYS AS (
    house_number::text
    || coalesce(' ' || pre_direction, '')
    || ' ' || street_name
    || coalesce(' FL ' || floor, '')
    || coalesce(' #' || unit, '')
  ) STORED;

ALTER TABLE core.address
  ADD CONSTRAINT address_full_key_uq UNIQUE (jurisdiction_id, full_key);

CREATE INDEX address_base_idx ON core.address (jurisdiction_id, base_key);

-- A business at 1000-1002 can have a permit filed at 1002, so matching looks up
-- a street and then compares number ranges.
CREATE INDEX address_street_idx ON core.address (jurisdiction_id, pre_direction, street_name, house_number);

-- ---------------------------------------------------------------------------
-- Vocabulary mappings: each city's own words become data, not code
-- ---------------------------------------------------------------------------

CREATE TABLE ref.party_role (
  code text PRIMARY KEY CHECK (code ~ '^[a-z_]+$'),
  name text NOT NULL
);

INSERT INTO ref.party_role (code, name) VALUES
  ('owner',               'Property owner'),
  ('tenant',              'Tenant'),
  ('applicant',           'Applicant'),
  ('contractor',          'Contractor'),
  ('design_professional', 'Architect or engineer'),
  ('expediter',           'Permit expediter'),
  ('other',               'Other');

CREATE TABLE ref.permit_type_map (
  source_id            smallint NOT NULL REFERENCES ref.source,
  permit_type_raw      text NOT NULL,
  -- Empty means "any work type"; a non-empty row overrides it for that work type.
  work_type_raw        text NOT NULL DEFAULT '',
  permit_category_code text NOT NULL REFERENCES ref.permit_category,
  PRIMARY KEY (source_id, permit_type_raw, work_type_raw)
);

CREATE TABLE ref.contact_type_map (
  source_id        smallint NOT NULL REFERENCES ref.source,
  contact_type_raw text NOT NULL,
  role_code        text NOT NULL REFERENCES ref.party_role,
  trade            text,
  PRIMARY KEY (source_id, contact_type_raw)
);

CREATE TABLE ref.license_type_map (
  source_id              smallint NOT NULL REFERENCES ref.source,
  license_type_raw       text NOT NULL,
  business_category_code text NOT NULL REFERENCES ref.business_category,
  PRIMARY KEY (source_id, license_type_raw)
);

CREATE TABLE ref.business_activity_map (
  source_id              smallint NOT NULL REFERENCES ref.source,
  activity_raw           text NOT NULL,
  business_category_code text NOT NULL REFERENCES ref.business_category,
  -- A license can list several activities. The lowest number wins, so a grocery
  -- that also sells coffee stays a grocery.
  priority               smallint NOT NULL,
  PRIMARY KEY (source_id, activity_raw)
);

-- ---------------------------------------------------------------------------
-- Business categories
-- ---------------------------------------------------------------------------

-- The single "food" category is replaced: the business_activity field separates
-- restaurants from grocery-type food retail.
DELETE FROM ref.business_category WHERE code = 'food';

INSERT INTO ref.business_category (code, name) VALUES
  ('restaurant',  'Restaurant or other prepared-food business'),
  ('food_retail', 'Grocery or other food retail'),
  ('bar',         'Tavern')
ON CONFLICT (code) DO NOTHING;

UPDATE ref.business_category
SET name = 'Liquor license held alongside another business'
WHERE code = 'liquor';

-- ---------------------------------------------------------------------------
-- Permits, parties, licenses
-- ---------------------------------------------------------------------------

ALTER TABLE core.permit
  ADD COLUMN work_type_raw text;

ALTER TABLE core.permit_party
  DROP CONSTRAINT permit_party_role_check,
  ADD CONSTRAINT permit_party_role_fk FOREIGN KEY (role) REFERENCES ref.party_role;

ALTER TABLE core.business_license
  ADD COLUMN business_activity_raw text,
  -- "relocation" is an existing business opening at a new address, which is a
  -- lead in its own right and must not be folded into "change".
  DROP CONSTRAINT business_license_application_type_check,
  ADD CONSTRAINT business_license_application_type_check
    CHECK (application_type IN ('new', 'renewal', 'relocation', 'change', 'other'));
