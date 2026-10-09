-- Normalize Chicago business licenses from raw into core, including parsing the
-- free-text address against the street list built by the permits transform.
-- Run the permits transform first. Re-runnable. Run by "npm run normalize".

-- 0. Helpers, for this session only ------------------------------------------

CREATE OR REPLACE FUNCTION pg_temp.to_date_or_null(value text) RETURNS date
LANGUAGE sql IMMUTABLE
RETURN CASE WHEN value ~ '^\d{4}-\d{2}-\d{2}' THEN left(value, 10)::date END;

-- Chicago writes the floor many ways ("1ST", "1", "GROUND", "BSMT"). One spelling
-- per floor, so the same premises always gets the same key. "0" is a placeholder
-- meaning no floor.
CREATE OR REPLACE FUNCTION pg_temp.is_floor(token text) RETURNS boolean
LANGUAGE sql IMMUTABLE
RETURN token ~ '^\d{1,3}(ST|ND|RD|TH)?$'
    OR token IN ('BSMT', 'BASEMENT', 'LL', 'LOWER', 'GROUND', 'GRND', 'GRD', 'MEZZ', 'MEZZANINE');

CREATE OR REPLACE FUNCTION pg_temp.norm_floor(token text) RETURNS text
LANGUAGE sql IMMUTABLE
RETURN CASE
  WHEN token ~ '^\d{1,3}(ST|ND|RD|TH)?$' THEN nullif(ltrim(substring(token FROM '^\d+'), '0'), '')
  WHEN token IN ('BSMT', 'BASEMENT') THEN 'B'
  WHEN token IN ('LL', 'LOWER') THEN 'LL'
  WHEN token IN ('GROUND', 'GRND', 'GRD') THEN '1'
  WHEN token IN ('MEZZ', 'MEZZANINE') THEN 'M'
END;

-- "STE 100", "UNIT 100", "#100" and "100" are one suite.
CREATE OR REPLACE FUNCTION pg_temp.norm_unit(value text) RETURNS text
LANGUAGE sql IMMUTABLE
RETURN (
  SELECT CASE WHEN v ~ '^\d+$' THEN nullif(ltrim(v, '0'), '') ELSE nullif(v, '') END
  FROM (
    SELECT btrim(regexp_replace(
             regexp_replace(replace(upper(value), '#', ' '), '^\s*(UNIT|STE|SUITE|SPACE|SPC|RM|ROOM|APT|NO)\.?(\s+|$)', ''),
             '\s+', ' ', 'g')) AS v
  ) AS cleaned
);

-- 1. Current raw records for this source --------------------------------------

CREATE TEMP TABLE src ON COMMIT DROP AS
SELECT r.record_id, r.source_id, s.jurisdiction_id, r.payload
FROM raw.record r
JOIN ref.source s USING (source_id)
WHERE s.code = 'chicago-business-licenses'
  AND r.superseded_at IS NULL;
ANALYZE src;

-- 2. Typed columns ------------------------------------------------------------

CREATE TEMP TABLE lic_in ON COMMIT DROP AS
SELECT
  record_id, source_id, jurisdiction_id,
  payload ->> 'license_id' AS source_license_key,
  payload ->> 'account_number' AS account_number,
  payload ->> 'site_number' AS site_number,
  payload ->> 'license_number' AS license_number,
  coalesce(nullif(btrim(payload ->> 'legal_name'), ''), nullif(btrim(payload ->> 'doing_business_as_name'), ''), '(not given)') AS legal_name,
  nullif(btrim(payload ->> 'doing_business_as_name'), '') AS dba_name,
  -- Kept exactly as published: the spacing carries meaning (see step 4).
  coalesce(payload ->> 'address', '') AS address_raw,
  upper(btrim(payload ->> 'city')) AS city,
  payload ->> 'license_description' AS license_type_raw,
  nullif(btrim(payload ->> 'business_activity'), '') AS business_activity_raw,
  payload ->> 'application_type' AS application_type_raw,
  CASE
    WHEN payload ->> 'application_type' = 'ISSUE' THEN 'new'
    WHEN payload ->> 'application_type' = 'RENEW' THEN 'renewal'
    WHEN payload ->> 'application_type' = 'C_LOC' THEN 'relocation'
    WHEN payload ->> 'application_type' LIKE 'C\_%' THEN 'change'
    ELSE 'other'
  END AS application_type,
  pg_temp.to_date_or_null(payload ->> 'application_created_date') AS applied_on,
  pg_temp.to_date_or_null(payload ->> 'date_issued') AS issued_on,
  pg_temp.to_date_or_null(payload ->> 'license_start_date') AS starts_on,
  pg_temp.to_date_or_null(payload ->> 'expiration_date') AS expires_on,
  payload ->> 'license_status' AS status_raw,
  CASE WHEN payload ->> 'latitude'  ~ '^-?\d+(\.\d+)?$' THEN (payload ->> 'latitude')::double precision END AS latitude,
  CASE WHEN payload ->> 'longitude' ~ '^-?\d+(\.\d+)?$' THEN (payload ->> 'longitude')::double precision END AS longitude
FROM src;
ANALYZE lic_in;

-- 3. Business category --------------------------------------------------------
-- The license type decides the family. A Retail Food license is refined by its
-- business activities; the lowest-priority mapped activity wins.

CREATE TEMP TABLE lic_category ON COMMIT DROP AS
SELECT
  l.record_id,
  CASE
    WHEN lt.business_category_code = 'food_unclassified' THEN coalesce(
      (SELECT m.business_category_code
       FROM unnest(string_to_array(l.business_activity_raw, ' | ')) AS a(activity)
       JOIN ref.business_activity_map m
         ON m.source_id = l.source_id AND m.activity_raw = btrim(a.activity)
       ORDER BY m.priority, m.business_category_code
       LIMIT 1),
      'food_unclassified')
    ELSE coalesce(lt.business_category_code, 'other')
  END AS business_category_code
FROM lic_in l
LEFT JOIN ref.license_type_map lt
  ON lt.source_id = l.source_id AND lt.license_type_raw = l.license_type_raw;
ANALYZE lic_category;

-- 4. Address parsing (Chicago addresses only) ---------------------------------
-- Shape: number (or range), direction, street, then optional floor and suite.
-- The published address is street, floor, and suite joined by single spaces,
-- so an empty floor leaves two spaces in a row before the suite.

-- 4a. Number, optional range, direction, and everything after.
CREATE TEMP TABLE addr_parse ON COMMIT DROP AS
SELECT l.record_id, l.jurisdiction_id,
       m[1] AS number_raw, m[2] AS high_raw, m[3] AS pre_direction, btrim(m[4]) AS rest
FROM lic_in l
CROSS JOIN LATERAL regexp_match(
  upper(btrim(l.address_raw)),
  '^(\d{1,7})(?:-?[A-Z])?(?:\s*-\s*(\d{1,7})(?:-?[A-Z])?)?(?:\s*-?\s*1/2)?\s+([NSEW])\s+(.+)$') AS m
WHERE l.city = 'CHICAGO'
  AND m IS NOT NULL;
ANALYZE addr_parse;

-- 4b. The longest known street at the start of the rest.
-- Every 1- to 6-word prefix of the rest becomes a candidate street name, then
-- candidates are matched to the street list with a plain equality join. (Testing
-- each address against each street instead was the cause of a 32-minute run.)
CREATE TEMP TABLE addr_candidate ON COMMIT DROP AS
SELECT p.record_id, p.jurisdiction_id, p.pre_direction, n AS street_words,
       array_to_string(w.words[1:n], ' ') AS candidate
FROM addr_parse p
CROSS JOIN LATERAL (SELECT regexp_split_to_array(regexp_replace(p.rest, '\s+', ' ', 'g'), ' ') AS words) AS w
CROSS JOIN LATERAL generate_series(1, least(6, cardinality(w.words))) AS n;
ANALYZE addr_candidate;

CREATE TEMP TABLE addr_street ON COMMIT DROP AS
SELECT DISTINCT ON (c.record_id) c.record_id, c.street_words, st.name AS street_name
FROM addr_candidate c
JOIN core.street st
  ON  st.jurisdiction_id = c.jurisdiction_id
  AND st.pre_direction = c.pre_direction
  AND st.name = c.candidate
ORDER BY c.record_id, c.street_words DESC;
ANALYZE addr_street;

-- 4c. Split what follows the street into the separator and the tail.
CREATE TEMP TABLE addr_tail ON COMMIT DROP AS
SELECT p.record_id, p.jurisdiction_id, p.pre_direction, s.street_name,
       p.number_raw::integer AS house_number,
       -- "5300 - 04" is shorthand for 5300-5304.
       CASE
         WHEN p.high_raw IS NULL THEN NULL
         WHEN length(p.high_raw) < length(p.number_raw)
           THEN (left(p.number_raw, length(p.number_raw) - length(p.high_raw)) || p.high_raw)::integer
         ELSE p.high_raw::integer
       END AS high_candidate,
       m[1] AS separator,
       btrim(m[2]) AS tail
FROM addr_parse p
JOIN addr_street s USING (record_id)
CROSS JOIN LATERAL regexp_match(p.rest, '^\S+(?:\s+\S+){' || (s.street_words - 1) || '}(\s*)(.*)$') AS m;
ANALYZE addr_tail;

-- 4d. Floor and suite.
CREATE TEMP TABLE addr_full ON COMMIT DROP AS
SELECT t.record_id, t.jurisdiction_id, t.house_number,
       CASE WHEN t.high_candidate > t.house_number THEN t.high_candidate END AS house_number_high,
       t.pre_direction, t.street_name, t.tail,
       f.floor, f.unit
FROM addr_tail t
CROSS JOIN LATERAL (SELECT regexp_split_to_array(t.tail, '\s+') AS tok) AS k
CROSS JOIN LATERAL (
  SELECT
    CASE
      WHEN t.tail = '' THEN NULL
      WHEN length(t.separator) >= 2 AND k.tok[1] !~ '^\d{1,3}(ST|ND|RD|TH)$' THEN NULL
      WHEN pg_temp.is_floor(k.tok[1]) THEN pg_temp.norm_floor(k.tok[1])
      WHEN k.tok[1] IN ('FL', 'FLR', 'FLOOR') AND pg_temp.is_floor(k.tok[2]) THEN pg_temp.norm_floor(k.tok[2])
    END AS floor,
    CASE
      WHEN t.tail = '' THEN NULL
      -- Two spaces: the floor field was empty, so everything left is the suite,
      -- unless it starts with an ordinal ("1ST"), which can only be a floor.
      WHEN length(t.separator) >= 2 AND k.tok[1] !~ '^\d{1,3}(ST|ND|RD|TH)$' THEN pg_temp.norm_unit(t.tail)
      WHEN pg_temp.is_floor(k.tok[1]) OR (k.tok[1] IN ('FL', 'FLR', 'FLOOR') AND pg_temp.is_floor(k.tok[2])) THEN (
        SELECT CASE
          -- "1ST & 2ND": several floors, no suite.
          WHEN after ~ '^[&,+]' THEN NULL
          ELSE pg_temp.norm_unit(regexp_replace(after, '^(FL|FLR|FLOOR)\.?(\s+|$)', ''))
        END
        FROM (SELECT btrim(array_to_string(
                k.tok[CASE WHEN pg_temp.is_floor(k.tok[1]) THEN 2 ELSE 3 END :], ' ')) AS after) AS a)
      ELSE pg_temp.norm_unit(t.tail)
    END AS unit
) AS f;

ALTER TABLE addr_full ADD COLUMN address_key text;
UPDATE addr_full SET address_key =
  house_number::text
  || coalesce('-' || house_number_high::text, '')
  || coalesce(' ' || pre_direction, '')
  || ' ' || street_name
  || coalesce(' FL ' || floor, '')
  || coalesce(' #' || unit, '');
ANALYZE addr_full;

-- 5. Addresses ----------------------------------------------------------------
-- Premises-level rows. A building address created by the permits transform keeps
-- its coordinates; new rows take them from the license.

INSERT INTO core.address (jurisdiction_id, house_number, house_number_high, pre_direction, street_name, floor, unit, geog)
SELECT DISTINCT ON (a.address_key)
  a.jurisdiction_id, a.house_number, a.house_number_high, a.pre_direction, a.street_name, a.floor, a.unit,
  CASE WHEN l.latitude IS NOT NULL AND l.longitude IS NOT NULL
       THEN ST_SetSRID(ST_MakePoint(l.longitude, l.latitude), 4326)::geography END
FROM addr_full a
JOIN lic_in l USING (record_id)
ORDER BY a.address_key, (l.latitude IS NULL), a.record_id
ON CONFLICT DO NOTHING;

-- 6. Licenses -----------------------------------------------------------------

INSERT INTO core.business_license (
  record_id, source_id, jurisdiction_id, source_license_key, account_number, site_number, license_number,
  legal_name, dba_name, address_id, address_raw, license_type_raw, business_activity_raw,
  business_category_code, application_type, application_type_raw,
  applied_on, issued_on, starts_on, expires_on, status_raw)
SELECT
  l.record_id, l.source_id, l.jurisdiction_id, l.source_license_key, l.account_number, l.site_number, l.license_number,
  l.legal_name, l.dba_name, ad.address_id, l.address_raw, l.license_type_raw, l.business_activity_raw,
  c.business_category_code, l.application_type, l.application_type_raw,
  l.applied_on, l.issued_on, l.starts_on, l.expires_on, l.status_raw
FROM lic_in l
JOIN lic_category c USING (record_id)
LEFT JOIN addr_full a USING (record_id)
LEFT JOIN core.address ad ON ad.jurisdiction_id = a.jurisdiction_id AND ad.full_key = a.address_key
ON CONFLICT (source_id, source_license_key) DO UPDATE SET
  record_id              = EXCLUDED.record_id,
  account_number         = EXCLUDED.account_number,
  site_number            = EXCLUDED.site_number,
  license_number         = EXCLUDED.license_number,
  legal_name             = EXCLUDED.legal_name,
  dba_name               = EXCLUDED.dba_name,
  address_id             = EXCLUDED.address_id,
  address_raw            = EXCLUDED.address_raw,
  license_type_raw       = EXCLUDED.license_type_raw,
  business_activity_raw  = EXCLUDED.business_activity_raw,
  business_category_code = EXCLUDED.business_category_code,
  application_type       = EXCLUDED.application_type,
  application_type_raw   = EXCLUDED.application_type_raw,
  applied_on             = EXCLUDED.applied_on,
  issued_on              = EXCLUDED.issued_on,
  starts_on              = EXCLUDED.starts_on,
  expires_on             = EXCLUDED.expires_on,
  status_raw             = EXCLUDED.status_raw;

ANALYZE core.address, core.business_license;

-- 7. Report -------------------------------------------------------------------

CREATE TEMP TABLE parse_outcome ON COMMIT DROP AS
SELECT l.record_id, l.address_raw,
  CASE
    WHEN l.city IS DISTINCT FROM 'CHICAGO' THEN '6 outside Chicago'
    WHEN l.address_raw ILIKE '%REDACTED%' THEN '5 redacted'
    WHEN p.record_id IS NULL THEN '4 no number and direction'
    WHEN s.record_id IS NULL THEN '3 street not in list'
    WHEN a.floor IS NULL AND a.unit IS NULL THEN '1 parsed: building only'
    WHEN a.unit IS NULL THEN '1 parsed: floor'
    WHEN a.floor IS NULL THEN '1 parsed: suite'
    ELSE '1 parsed: floor and suite'
  END AS outcome
FROM lic_in l
LEFT JOIN addr_parse p USING (record_id)
LEFT JOIN addr_street s USING (record_id)
LEFT JOIN addr_full a USING (record_id);
ANALYZE parse_outcome;

SELECT 'totals' AS report,
  (SELECT count(*)::int FROM src)                                                  AS raw_records,
  (SELECT count(*)::int FROM core.business_license b JOIN src USING (record_id))   AS licenses,
  (SELECT count(*)::int FROM core.business_license b JOIN src USING (record_id) WHERE b.address_id IS NOT NULL) AS with_address,
  (SELECT count(DISTINCT b.address_id)::int FROM core.business_license b JOIN src USING (record_id)) AS distinct_premises,
  (SELECT count(*)::int FROM core.address)                                         AS addresses_total,
  (SELECT count(*)::int FROM core.address WHERE house_number_high IS NOT NULL)     AS addresses_with_range;

SELECT 'address parse outcome' AS report, outcome, count(*)::int AS licenses,
       round(100.0 * count(*) / sum(count(*)) OVER (), 2)::float8 AS pct
FROM parse_outcome GROUP BY outcome ORDER BY outcome;

SELECT 'new licenses and relocations by category' AS report, b.business_category_code AS category,
       (count(*) FILTER (WHERE b.application_type = 'new'))::int AS new,
       (count(*) FILTER (WHERE b.application_type = 'relocation'))::int AS relocation,
       (count(*) FILTER (WHERE b.application_type IN ('new', 'relocation') AND b.address_id IS NULL))::int AS without_address
FROM core.business_license b JOIN src USING (record_id)
WHERE b.application_type IN ('new', 'relocation')
GROUP BY 2 ORDER BY 3 DESC;

SELECT 'unmapped activities on unclassified food licenses' AS report, btrim(a.activity) AS activity, count(*)::int AS licenses
FROM core.business_license b
JOIN src USING (record_id)
CROSS JOIN LATERAL unnest(string_to_array(b.business_activity_raw, ' | ')) AS a(activity)
WHERE b.business_category_code = 'food_unclassified'
  AND NOT EXISTS (SELECT 1 FROM ref.business_activity_map m WHERE m.source_id = b.source_id AND m.activity_raw = btrim(a.activity))
GROUP BY 2 ORDER BY 3 DESC LIMIT 15;

SELECT 'sample of parsed addresses' AS report, o.address_raw, a.house_number_high AS high, a.floor, a.unit, ad.full_key
FROM (SELECT DISTINCT ON (address_raw) record_id, address_raw, outcome FROM parse_outcome ORDER BY address_raw, record_id) AS o
JOIN addr_full a USING (record_id)
JOIN core.address ad ON ad.full_key = a.address_key AND ad.jurisdiction_id = a.jurisdiction_id
WHERE o.outcome LIKE '1 %' AND (a.tail <> '' OR a.house_number_high IS NOT NULL)
ORDER BY md5(o.address_raw) LIMIT 30;

SELECT 'sample of unparsed Chicago addresses' AS report, outcome, address_raw
FROM (SELECT DISTINCT ON (address_raw) address_raw, outcome FROM parse_outcome
      WHERE outcome LIKE '3 %' OR outcome LIKE '4 %' ORDER BY address_raw) AS o
ORDER BY md5(address_raw) LIMIT 20;
