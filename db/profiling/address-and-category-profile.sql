-- Read-only follow-up profile. Changes nothing.
-- Tests three ideas raised by raw-profile.sql before any parser is designed.

\pset pager off

\echo
\echo === A. Is a double space the street/unit separator in license addresses? By start year ===
SELECT left(payload ->> 'license_start_date', 4) AS start_year,
       count(*) AS licenses,
       count(*) FILTER (WHERE payload ->> 'address' ~ '\S {2,}\S') AS has_double_space,
       round(100.0 * count(*) FILTER (WHERE payload ->> 'address' ~ '\S {2,}\S') / count(*), 1) AS pct
FROM raw.record r JOIN ref.source s USING (source_id)
WHERE s.code = 'chicago-business-licenses' AND r.superseded_at IS NULL
  AND upper(payload ->> 'city') = 'CHICAGO'
GROUP BY 1 ORDER BY 1;

\echo
\echo === B. When there is a double space: what comes after it, top 30 ===
WITH a AS (
  SELECT upper(btrim(payload ->> 'address')) AS addr
  FROM raw.record r JOIN ref.source s USING (source_id)
  WHERE s.code = 'chicago-business-licenses' AND r.superseded_at IS NULL
    AND upper(payload ->> 'city') = 'CHICAGO'
),
tail AS (
  SELECT regexp_replace(btrim((regexp_match(addr, '\S {2,}(\S.*)$'))[1]), '\s+', ' ', 'g') AS unit_text
  FROM a
)
SELECT regexp_replace(regexp_replace(unit_text, '\d', '9', 'g'), '[A-Z]{4,}', 'WORD', 'g') AS unit_pattern,
       count(*), max(unit_text) AS example
FROM tail
WHERE unit_text IS NOT NULL
GROUP BY 1 ORDER BY 2 DESC LIMIT 30;

\echo
\echo === C. Can permit street names act as a street list for parsing license addresses? ===
-- Permits store direction and street name as clean separate fields. If a license
-- address is "number, direction, then one of those names", the rest is the unit.
CREATE TEMP TABLE street AS
SELECT DISTINCT payload ->> 'street_direction' AS dir, payload ->> 'street_name' AS name
FROM raw.record r JOIN ref.source s USING (source_id)
WHERE s.code = 'chicago-building-permits' AND r.superseded_at IS NULL
  AND payload ->> 'street_name' IS NOT NULL;

CREATE TEMP TABLE lic_addr AS
SELECT upper(regexp_replace(btrim(payload ->> 'address'), '\s+', ' ', 'g')) AS addr, count(*) AS licenses
FROM raw.record r JOIN ref.source s USING (source_id)
WHERE s.code = 'chicago-business-licenses' AND r.superseded_at IS NULL
  AND upper(payload ->> 'city') = 'CHICAGO'
GROUP BY 1;

CREATE TEMP TABLE parsed AS
SELECT addr, licenses, m[1] AS dir, string_to_array(m[2], ' ') AS words
FROM lic_addr
CROSS JOIN LATERAL regexp_match(addr, '^\d+[A-Z]?(?: ?- ?\d+)?(?:[ -]1/2)? ([NSEW]) (.+)$') AS m
WHERE m IS NOT NULL;

CREATE TEMP TABLE matched AS
SELECT p.addr, max(n) AS street_words
FROM parsed p
CROSS JOIN LATERAL generate_series(1, least(6, cardinality(p.words))) AS n
JOIN street st ON st.dir = p.dir AND st.name = array_to_string(p.words[1:n], ' ')
GROUP BY p.addr;

SELECT (SELECT count(*) FROM street) AS street_names_from_permits;

SELECT
  sum(l.licenses) AS licenses,
  coalesce(sum(l.licenses) FILTER (WHERE p.addr IS NULL), 0) AS no_number_and_direction,
  coalesce(sum(l.licenses) FILTER (WHERE p.addr IS NOT NULL AND m.addr IS NULL), 0) AS street_not_in_list,
  coalesce(sum(l.licenses) FILTER (WHERE m.addr IS NOT NULL), 0) AS street_found,
  round(100.0 * sum(l.licenses) FILTER (WHERE m.addr IS NOT NULL) / sum(l.licenses), 2) AS pct_found
FROM lic_addr l
LEFT JOIN parsed p USING (addr)
LEFT JOIN matched m USING (addr);

\echo
\echo === D. Streets in license addresses that the permit list does not have, top 30 ===
SELECT p.dir, array_to_string(p.words[1:2], ' ') AS first_two_words, sum(p.licenses) AS licenses, min(p.addr) AS example
FROM parsed p
LEFT JOIN matched m USING (addr)
WHERE m.addr IS NULL
GROUP BY 1, 2 ORDER BY 3 DESC LIMIT 30;

\echo
\echo === E. Addresses with no leading number and direction, 20 examples ===
SELECT l.addr, l.licenses
FROM lic_addr l LEFT JOIN parsed p USING (addr)
WHERE p.addr IS NULL
ORDER BY l.licenses DESC LIMIT 20;

\echo
\echo === F. Food-related licenses: business_activity values, top 30 ===
SELECT payload ->> 'license_description' AS license_description,
       payload ->> 'business_activity' AS business_activity, count(*)
FROM raw.record r JOIN ref.source s USING (source_id)
WHERE s.code = 'chicago-business-licenses' AND r.superseded_at IS NULL
  AND payload ->> 'license_description' IN ('Retail Food Establishment', 'Tavern', 'Consumption on Premises - Incidental Activity')
GROUP BY 1, 2 ORDER BY 3 DESC LIMIT 30;

\echo
\echo === G. Permits that name a TENANT contact, by permit type ===
SELECT payload ->> 'permit_type' AS permit_type,
       count(*) AS permits,
       count(*) FILTER (WHERE EXISTS (
         SELECT 1 FROM jsonb_each_text(r.payload) kv
         WHERE kv.key ~ '^contact_\d+_type$' AND kv.value = 'TENANT')) AS with_tenant
FROM raw.record r JOIN ref.source s USING (source_id)
WHERE s.code = 'chicago-building-permits' AND r.superseded_at IS NULL
GROUP BY 1 ORDER BY 2 DESC;
