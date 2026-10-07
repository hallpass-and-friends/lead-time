-- Read-only profile of the raw layer. Changes nothing.
-- Answers: which fields exist and how often, and what shapes the addresses take.

\pset pager off
\timing off

\echo
\echo === 1. Field fill rates (contact_1_x .. contact_15_x collapsed to contact_N_x) ===
WITH cur AS (
  SELECT r.record_id, s.code, r.payload
  FROM raw.record r
  JOIN ref.source s USING (source_id)
  WHERE r.superseded_at IS NULL
),
totals AS (
  SELECT code, count(*) AS records FROM cur GROUP BY code
),
fields AS (
  SELECT c.code,
         regexp_replace(k.key, '^contact_\d+_', 'contact_N_') AS field,
         count(DISTINCT c.record_id) AS records_with_field
  FROM cur c
  CROSS JOIN LATERAL jsonb_object_keys(c.payload) AS k(key)
  WHERE k.key !~ '^:@computed'
  GROUP BY 1, 2
)
SELECT f.code, f.field, f.records_with_field,
       round(100.0 * f.records_with_field / t.records, 1) AS pct
FROM fields f
JOIN totals t USING (code)
ORDER BY f.code, f.records_with_field DESC, f.field;

\echo
\echo === 2. Permits: category fields ===
SELECT payload ->> 'permit_type' AS permit_type, count(*)
FROM raw.record r JOIN ref.source s USING (source_id)
WHERE s.code = 'chicago-building-permits' AND r.superseded_at IS NULL
GROUP BY 1 ORDER BY 2 DESC;

\echo
\echo === 3. Permits: address parts ===
SELECT
  count(*) AS permits,
  count(*) FILTER (WHERE payload ->> 'street_number' ~ '^\d+$')        AS number_is_digits,
  count(*) FILTER (WHERE payload ->> 'street_number' IS NULL)          AS number_missing,
  count(*) FILTER (WHERE payload ->> 'street_direction' IN ('N','S','E','W')) AS direction_nsew,
  count(*) FILTER (WHERE payload ->> 'street_direction' IS NULL)       AS direction_missing,
  count(*) FILTER (WHERE payload ->> 'street_name' IS NULL)            AS name_missing,
  count(*) FILTER (WHERE payload ->> 'street_name' <> upper(btrim(payload ->> 'street_name'))) AS name_not_clean_upper,
  count(*) FILTER (WHERE payload ->> 'latitude' IS NULL)               AS latitude_missing,
  count(*) FILTER (WHERE payload ->> 'pin_list' IS NULL)               AS pin_missing
FROM raw.record r JOIN ref.source s USING (source_id)
WHERE s.code = 'chicago-building-permits' AND r.superseded_at IS NULL;

\echo
\echo === 4. Permits: last word of street_name (the street type), top 30 ===
SELECT (regexp_match(payload ->> 'street_name', '(\S+)$'))[1] AS last_word, count(*)
FROM raw.record r JOIN ref.source s USING (source_id)
WHERE s.code = 'chicago-building-permits' AND r.superseded_at IS NULL
GROUP BY 1 ORDER BY 2 DESC LIMIT 30;

\echo
\echo === 5. Permits: contact types, top 40 ===
SELECT kv.value AS contact_type, count(*)
FROM raw.record r
JOIN ref.source s USING (source_id)
CROSS JOIN LATERAL jsonb_each_text(r.payload) AS kv(key, value)
WHERE s.code = 'chicago-building-permits' AND r.superseded_at IS NULL
  AND kv.key ~ '^contact_\d+_type$'
GROUP BY 1 ORDER BY 2 DESC LIMIT 40;

\echo
\echo === 6. Permits: date fill ===
SELECT
  count(*) FILTER (WHERE payload ->> 'application_start_date' IS NULL) AS application_start_missing,
  count(*) FILTER (WHERE payload ->> 'issue_date' IS NULL)             AS issue_missing,
  count(*) FILTER (WHERE (payload ->> 'application_start_date') > (payload ->> 'issue_date')) AS applied_after_issued
FROM raw.record r JOIN ref.source s USING (source_id)
WHERE s.code = 'chicago-building-permits' AND r.superseded_at IS NULL;

\echo
\echo === 7. Licenses: application types ===
SELECT payload ->> 'application_type' AS application_type, count(*),
       count(*) FILTER (WHERE payload ->> 'application_created_date' IS NULL) AS created_date_missing
FROM raw.record r JOIN ref.source s USING (source_id)
WHERE s.code = 'chicago-business-licenses' AND r.superseded_at IS NULL
GROUP BY 1 ORDER BY 2 DESC;

\echo
\echo === 8. Licenses: license descriptions, top 25 ===
SELECT payload ->> 'license_description' AS license_description, count(*)
FROM raw.record r JOIN ref.source s USING (source_id)
WHERE s.code = 'chicago-business-licenses' AND r.superseded_at IS NULL
GROUP BY 1 ORDER BY 2 DESC LIMIT 25;

\echo
\echo === 9. Licenses: where the business is ===
SELECT
  count(*) AS licenses,
  count(*) FILTER (WHERE upper(payload ->> 'city') = 'CHICAGO') AS city_chicago,
  count(*) FILTER (WHERE payload ->> 'city' IS NULL)            AS city_missing,
  count(*) FILTER (WHERE payload ->> 'address' IS NULL)         AS address_missing,
  count(*) FILTER (WHERE payload ->> 'latitude' IS NULL)        AS latitude_missing
FROM raw.record r JOIN ref.source s USING (source_id)
WHERE s.code = 'chicago-business-licenses' AND r.superseded_at IS NULL;

\echo
\echo === 10. Licenses in Chicago: address shapes ===
WITH a AS (
  SELECT upper(regexp_replace(btrim(payload ->> 'address'), '\s+', ' ', 'g')) AS addr
  FROM raw.record r JOIN ref.source s USING (source_id)
  WHERE s.code = 'chicago-business-licenses' AND r.superseded_at IS NULL
    AND upper(payload ->> 'city') = 'CHICAGO'
),
shaped AS (
  SELECT CASE
    WHEN addr IS NULL OR addr = '' THEN '0 missing'
    WHEN addr ~ '^\d+ [NSEW] .+ (ST|AVE|BLVD|RD|DR|PL|CT|PKWY|WAY|TER|LN|HWY|SQ|PLZ|CIR|ROW|WALK|EXPY)$' THEN '1 number dir street type'
    WHEN addr ~ '^\d+ [NSEW] BROADWAY$' THEN '1 number dir street type'
    WHEN addr ~ '^\d+ [NSEW] .+ (ST|AVE|BLVD|RD|DR|PL|CT|PKWY|WAY|TER|LN|HWY|SQ|PLZ|CIR|ROW|WALK|EXPY|BROADWAY) .+$' THEN '2 same, then a unit or floor'
    WHEN addr ~ '^\d+-\d+ [NSEW] ' THEN '3 number range'
    WHEN addr ~ '^\d+ [NSEW] ' THEN '4 number dir, unrecognized street type'
    WHEN addr ~ '^\d+ ' THEN '5 number, no direction'
    ELSE '6 other'
  END AS shape
  FROM a
)
SELECT shape, count(*), round(100.0 * count(*) / sum(count(*)) OVER (), 2) AS pct
FROM shaped GROUP BY 1 ORDER BY 1;

\echo
\echo === 11. Licenses in Chicago: what follows the street type (unit forms), top 40 ===
WITH a AS (
  SELECT upper(regexp_replace(btrim(payload ->> 'address'), '\s+', ' ', 'g')) AS addr
  FROM raw.record r JOIN ref.source s USING (source_id)
  WHERE s.code = 'chicago-business-licenses' AND r.superseded_at IS NULL
    AND upper(payload ->> 'city') = 'CHICAGO'
),
tail AS (
  SELECT (regexp_match(addr, '^\d+ [NSEW] .+? (?:ST|AVE|BLVD|RD|DR|PL|CT|PKWY|WAY|TER|LN|HWY|SQ|PLZ|CIR|ROW|WALK|EXPY|BROADWAY) (.+)$'))[1] AS unit_text
  FROM a
)
SELECT regexp_replace(regexp_replace(unit_text, '\d', '9', 'g'), '[A-Z]{4,}', 'WORD', 'g') AS unit_pattern,
       count(*), min(unit_text) AS example
FROM tail
WHERE unit_text IS NOT NULL
GROUP BY 1 ORDER BY 2 DESC LIMIT 40;

\echo
\echo === 12. Licenses in Chicago: examples of the harder shapes ===
WITH a AS (
  SELECT DISTINCT upper(regexp_replace(btrim(payload ->> 'address'), '\s+', ' ', 'g')) AS addr
  FROM raw.record r JOIN ref.source s USING (source_id)
  WHERE s.code = 'chicago-business-licenses' AND r.superseded_at IS NULL
    AND upper(payload ->> 'city') = 'CHICAGO'
)
(SELECT '3 number range' AS shape, addr FROM a WHERE addr ~ '^\d+-\d+ [NSEW] ' ORDER BY addr LIMIT 8)
UNION ALL
(SELECT '4 unrecognized street type', addr FROM a
  WHERE addr ~ '^\d+ [NSEW] ' AND addr !~ ' (ST|AVE|BLVD|RD|DR|PL|CT|PKWY|WAY|TER|LN|HWY|SQ|PLZ|CIR|ROW|WALK|EXPY|BROADWAY)( |$)' ORDER BY md5(addr) LIMIT 12)
UNION ALL
(SELECT '5 number, no direction', addr FROM a WHERE addr ~ '^\d+ ' AND addr !~ '^\d+ [NSEW] ' AND addr !~ '^\d+-\d+ ' ORDER BY md5(addr) LIMIT 8)
UNION ALL
(SELECT '6 other', addr FROM a WHERE addr !~ '^\d+ ' AND addr !~ '^\d+-\d+ ' ORDER BY md5(addr) LIMIT 8);
