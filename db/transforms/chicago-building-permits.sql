-- Normalize Chicago building permits from raw into core.
-- Re-runnable: every step inserts what is missing or updates in place.
-- Run by "npm run normalize", inside one transaction.

-- 1. Current raw records for this source ------------------------------------

CREATE TEMP TABLE src ON COMMIT DROP AS
SELECT r.record_id, r.source_id, s.jurisdiction_id, r.payload
FROM raw.record r
JOIN ref.source s USING (source_id)
WHERE s.code = 'chicago-building-permits'
  AND r.superseded_at IS NULL;

-- 2. Pull typed columns out of the JSON once ---------------------------------
-- Every cast is guarded by a pattern, so one malformed value becomes NULL
-- instead of failing the whole run.

CREATE TEMP TABLE permit_in ON COMMIT DROP AS
SELECT
  record_id, source_id, jurisdiction_id,
  payload ->> 'permit_' AS permit_number,
  CASE WHEN payload ->> 'street_number' ~ '^\d{1,9}$' THEN (payload ->> 'street_number')::integer END AS house_number,
  nullif(upper(btrim(payload ->> 'street_direction')), '') AS pre_direction,
  nullif(upper(regexp_replace(btrim(payload ->> 'street_name'), '\s+', ' ', 'g')), '') AS street_name,
  concat_ws(' ', payload ->> 'street_number', payload ->> 'street_direction', payload ->> 'street_name') AS address_raw,
  payload ->> 'permit_type' AS permit_type_raw,
  payload ->> 'work_type' AS work_type_raw,
  payload ->> 'work_description' AS work_description,
  CASE WHEN payload ->> 'application_start_date' ~ '^\d{4}-\d{2}-\d{2}' THEN left(payload ->> 'application_start_date', 10)::date END AS applied_on,
  CASE WHEN payload ->> 'issue_date' ~ '^\d{4}-\d{2}-\d{2}' THEN left(payload ->> 'issue_date', 10)::date END AS issued_on,
  CASE WHEN payload ->> 'reported_cost' ~ '^\d{1,12}(\.\d+)?$' THEN round((payload ->> 'reported_cost')::numeric, 2) END AS reported_cost,
  payload ->> 'permit_status' AS status_raw,
  CASE WHEN payload ->> 'latitude'  ~ '^-?\d+(\.\d+)?$' THEN (payload ->> 'latitude')::double precision END AS latitude,
  CASE WHEN payload ->> 'longitude' ~ '^-?\d+(\.\d+)?$' THEN (payload ->> 'longitude')::double precision END AS longitude
FROM src;

-- 3. Street list -------------------------------------------------------------

INSERT INTO core.street (jurisdiction_id, pre_direction, name)
SELECT DISTINCT jurisdiction_id, pre_direction, street_name
FROM permit_in
WHERE street_name IS NOT NULL
ON CONFLICT DO NOTHING;

-- 4. Addresses ---------------------------------------------------------------
-- Permits carry no floor or suite, so each one maps to a building-level address.
-- Where several permits share an address, the coordinates come from one that has them.

INSERT INTO core.address (jurisdiction_id, house_number, pre_direction, street_name, geog)
SELECT DISTINCT ON (jurisdiction_id, house_number, pre_direction, street_name)
  jurisdiction_id, house_number, pre_direction, street_name,
  CASE WHEN latitude IS NOT NULL AND longitude IS NOT NULL
       THEN ST_SetSRID(ST_MakePoint(longitude, latitude), 4326)::geography END
FROM permit_in
WHERE house_number IS NOT NULL AND street_name IS NOT NULL
ORDER BY jurisdiction_id, house_number, pre_direction, street_name, (latitude IS NULL), record_id
ON CONFLICT DO NOTHING;

-- 5. Permits -----------------------------------------------------------------

INSERT INTO core.permit (
  record_id, source_id, jurisdiction_id, permit_number, address_id, address_raw,
  permit_type_raw, work_type_raw, permit_category_code, work_description,
  applied_on, issued_on, reported_cost, status_raw)
SELECT
  p.record_id, p.source_id, p.jurisdiction_id, p.permit_number, a.address_id, p.address_raw,
  p.permit_type_raw, p.work_type_raw,
  -- A row for the exact work type wins over the permit type's general row.
  coalesce(by_work.permit_category_code, by_type.permit_category_code, 'other'),
  p.work_description, p.applied_on, p.issued_on, p.reported_cost, p.status_raw
FROM permit_in p
LEFT JOIN core.address a
  ON  a.jurisdiction_id = p.jurisdiction_id
  AND a.full_key = p.house_number::text || coalesce(' ' || p.pre_direction, '') || ' ' || p.street_name
LEFT JOIN ref.permit_type_map by_work
  ON  by_work.source_id = p.source_id
  AND by_work.permit_type_raw = p.permit_type_raw
  AND by_work.work_type_raw = p.work_type_raw
LEFT JOIN ref.permit_type_map by_type
  ON  by_type.source_id = p.source_id
  AND by_type.permit_type_raw = p.permit_type_raw
  AND by_type.work_type_raw = ''
ON CONFLICT (source_id, permit_number) DO UPDATE SET
  record_id            = EXCLUDED.record_id,
  address_id           = EXCLUDED.address_id,
  address_raw          = EXCLUDED.address_raw,
  permit_type_raw      = EXCLUDED.permit_type_raw,
  work_type_raw        = EXCLUDED.work_type_raw,
  permit_category_code = EXCLUDED.permit_category_code,
  work_description     = EXCLUDED.work_description,
  applied_on           = EXCLUDED.applied_on,
  issued_on            = EXCLUDED.issued_on,
  reported_cost        = EXCLUDED.reported_cost,
  status_raw           = EXCLUDED.status_raw;

-- 6. Parties -----------------------------------------------------------------
-- A permit lists its contacts as numbered fields (contact_1_type, contact_1_name, ...).
-- This turns them into one row per contact.

CREATE TEMP TABLE contact_in ON COMMIT DROP AS
SELECT s.record_id, s.source_id, s.jurisdiction_id,
       kv.value AS contact_type_raw,
       btrim(s.payload ->> replace(kv.key, '_type', '_name')) AS name,
       core.normalize_name(s.payload ->> replace(kv.key, '_type', '_name')) AS name_norm
FROM src s
CROSS JOIN LATERAL jsonb_each_text(s.payload) AS kv(key, value)
WHERE kv.key ~ '^contact_\d+_type$';

-- A name that normalizes to nothing (blank, or only a legal-form word) cannot identify a party.
DELETE FROM contact_in WHERE name_norm IS NULL;

INSERT INTO core.party (jurisdiction_id, display_name)
SELECT DISTINCT ON (jurisdiction_id, name_norm) jurisdiction_id, name
FROM contact_in
ORDER BY jurisdiction_id, name_norm, name
ON CONFLICT DO NOTHING;

-- Contacts are replaced as a set, so a contact removed at the source disappears here too.
DELETE FROM core.permit_party pp
USING core.permit p
WHERE pp.permit_id = p.permit_id
  AND p.source_id = (SELECT source_id FROM ref.source WHERE code = 'chicago-building-permits');

INSERT INTO core.permit_party (permit_id, party_id, role, role_raw, trade)
SELECT DISTINCT p.permit_id, pa.party_id, coalesce(m.role_code, 'other'), c.contact_type_raw, m.trade
FROM contact_in c
JOIN core.permit p ON p.record_id = c.record_id
JOIN core.party pa ON pa.jurisdiction_id = c.jurisdiction_id AND pa.name_norm = c.name_norm
LEFT JOIN ref.contact_type_map m ON m.source_id = c.source_id AND m.contact_type_raw = c.contact_type_raw;

ANALYZE core.street, core.address, core.permit, core.party, core.permit_party;

-- 7. Remove addresses nothing refers to ---------------------------------------
-- A rerun can change how an address parses, which leaves the old premises row
-- behind with nothing pointing to it. Every table that refers to an address is
-- listed; if a new one is added later and missed here, its foreign key makes this
-- delete fail loudly instead of removing an address still in use.

WITH removed AS (
  DELETE FROM core.address a
  WHERE NOT EXISTS (SELECT 1 FROM core.permit p           WHERE p.address_id = a.address_id)
    AND NOT EXISTS (SELECT 1 FROM core.business_license b WHERE b.address_id = a.address_id)
    AND NOT EXISTS (SELECT 1 FROM lead.signal s           WHERE s.address_id = a.address_id)
    AND NOT EXISTS (SELECT 1 FROM lead.lead l             WHERE l.address_id = a.address_id)
  RETURNING 1
)
SELECT 'cleanup' AS report, count(*)::int AS unreferenced_addresses_removed FROM removed;

-- 8. Report ------------------------------------------------------------------

SELECT 'totals' AS report,
  (SELECT count(*)::int FROM src)                                         AS raw_records,
  (SELECT count(*)::int FROM core.permit p JOIN src USING (record_id))    AS permits,
  (SELECT count(*)::int FROM core.permit p JOIN src USING (record_id) WHERE p.address_id IS NULL) AS permits_without_address,
  (SELECT count(*)::int FROM core.street)                                 AS streets,
  (SELECT count(*)::int FROM core.address)                                AS addresses,
  (SELECT count(*)::int FROM core.address WHERE geog IS NULL)             AS addresses_without_location,
  (SELECT count(*)::int FROM core.party)                                  AS parties,
  (SELECT count(*)::int FROM core.permit_party)                           AS permit_contacts;

SELECT 'permits by category' AS report, p.permit_category_code AS category, count(*)::int AS permits,
       (count(*) FILTER (WHERE p.applied_on IS NULL))::int AS without_applied_date
FROM core.permit p JOIN src USING (record_id)
GROUP BY 2 ORDER BY 3 DESC;

SELECT 'unmapped permit types' AS report, p.permit_type_raw, p.work_type_raw, count(*)::int AS permits
FROM permit_in p
WHERE NOT EXISTS (
  SELECT 1 FROM ref.permit_type_map m
  WHERE m.source_id = p.source_id AND m.permit_type_raw = p.permit_type_raw)
GROUP BY 2, 3 ORDER BY 4 DESC LIMIT 20;

SELECT 'contacts by role' AS report, pp.role, count(*)::int AS contacts, count(DISTINCT pp.party_id)::int AS distinct_parties
FROM core.permit_party pp
GROUP BY 2 ORDER BY 3 DESC;

SELECT 'unmapped contact types' AS report, c.contact_type_raw, count(*)::int AS contacts
FROM contact_in c
WHERE NOT EXISTS (
  SELECT 1 FROM ref.contact_type_map m
  WHERE m.source_id = c.source_id AND m.contact_type_raw = c.contact_type_raw)
GROUP BY 2 ORDER BY 3 DESC LIMIT 20;
