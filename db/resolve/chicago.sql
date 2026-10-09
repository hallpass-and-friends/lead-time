-- Resolve, Chicago, version 1.
-- For every opening: what was at the site before (site class). For every
-- build-out permit at an opening's building in the two years before it: a scored
-- link with its evidence. Each run is a new resolve.match_run, so versions can be
-- compared; earlier runs are kept until deleted (deleting a match_run removes its
-- rows). Run with: npm run resolve -- chicago
--
-- Steps:
--   1. open the run (its weights are stored in match_run.params and read from there)
--   2. openings, earlier licenses, build-out permits
--   3. site class for every opening
--   4. candidate pairs: build-out permits at the building, whole number range
--   5. evidence, score, decision; store the links
--   6. close the run
--   7. report

-- 1. Open the run. Every number the scoring uses lives here, so a run records
-- exactly how it was scored. Thresholds are 0.7 and 0.45, not the 0.6 and 0.4 in
-- the design note: with 0.6, a permit with no content evidence at all (starting
-- score, timing, one candidate, a site class that needs a build-out) would reach
-- "match" on circumstance alone.
INSERT INTO resolve.match_run (jurisdiction_id, algorithm_version, params, notes)
SELECT j.jurisdiction_id, 'chicago-v1', $json${
  "opening_categories": ["restaurant", "food_retail", "food_unclassified", "bar"],
  "opening_application_types": ["new", "relocation"],
  "buildout_categories": ["renovation", "new_construction"],
  "window_days_before": 730,
  "name_roles": ["owner", "tenant"],
  "food_words_pattern": "\\m(RESTAURANT|KITCHEN|HOOD|GREASE|CAFE|COFFEE|BAKERY|BAR|TAVERN|FOOD|DINING|PIZZA|GROCERY|DELI)\\M",
  "points": {
    "base": 0.30,
    "food_words": 0.25,
    "name_strong": 0.30,
    "name_weak": 0.15,
    "single_candidate": 0.15,
    "many_candidates": -0.10,
    "timing": 0.10,
    "class_needs_buildout": 0.10,
    "class_food_takeover": -0.05,
    "range_other_number": -0.05
  },
  "limits": {
    "name_strong_min": 0.6,
    "name_weak_min": 0.4,
    "many_candidates_min": 5,
    "timing_min_days": 30,
    "timing_max_days": 600,
    "match_min": 0.7,
    "possible_min": 0.45
  }
}$json$::jsonb,
  'Site classes and build-out permit links, hand-set points from the Resolve profile.'
FROM ref.jurisdiction j
WHERE j.code = 'us-il-chicago';

-- The id of the run just opened (same transaction, so nothing else can interleave).
CREATE TEMP TABLE run AS
SELECT match_run_id, params
FROM resolve.match_run
WHERE match_run_id = currval(pg_get_serial_sequence('resolve.match_run', 'match_run_id'));

-- The points and limits as typed columns, so the scoring below reads plainly.
CREATE TEMP TABLE w AS
SELECT
  (params -> 'points' ->> 'base')::numeric                 AS base,
  (params -> 'points' ->> 'food_words')::numeric           AS food_words,
  (params -> 'points' ->> 'name_strong')::numeric          AS name_strong,
  (params -> 'points' ->> 'name_weak')::numeric            AS name_weak,
  (params -> 'points' ->> 'single_candidate')::numeric     AS single_candidate,
  (params -> 'points' ->> 'many_candidates')::numeric      AS many_candidates,
  (params -> 'points' ->> 'timing')::numeric               AS timing,
  (params -> 'points' ->> 'class_needs_buildout')::numeric AS class_needs_buildout,
  (params -> 'points' ->> 'class_food_takeover')::numeric  AS class_food_takeover,
  (params -> 'points' ->> 'range_other_number')::numeric   AS range_other_number,
  (params -> 'limits' ->> 'name_strong_min')::real         AS name_strong_min,
  (params -> 'limits' ->> 'name_weak_min')::real           AS name_weak_min,
  (params -> 'limits' ->> 'many_candidates_min')::int      AS many_candidates_min,
  (params -> 'limits' ->> 'timing_min_days')::int          AS timing_min_days,
  (params -> 'limits' ->> 'timing_max_days')::int          AS timing_max_days,
  (params -> 'limits' ->> 'match_min')::numeric            AS match_min,
  (params -> 'limits' ->> 'possible_min')::numeric         AS possible_min,
  (params ->> 'window_days_before')::int                   AS window_days_before,
  params ->> 'food_words_pattern'                          AS food_words_pattern,
  ARRAY(SELECT jsonb_array_elements_text(params -> 'opening_categories'))        AS opening_categories,
  ARRAY(SELECT jsonb_array_elements_text(params -> 'opening_application_types')) AS opening_application_types,
  ARRAY(SELECT jsonb_array_elements_text(params -> 'buildout_categories'))       AS buildout_categories,
  ARRAY(SELECT jsonb_array_elements_text(params -> 'name_roles'))                AS name_roles
FROM run;

-- 2. Inputs.

-- Openings: new licenses and relocations in the food categories, with a parsed address.
CREATE TEMP TABLE opening AS
SELECT b.license_id, b.account_number, b.business_category_code AS category, b.application_type,
       b.legal_name_norm, b.dba_name_norm,
       coalesce(b.issued_on, b.starts_on) AS opened_on,
       a.base_key, a.full_key, a.house_number, a.house_number_high, a.pre_direction, a.street_name
FROM core.business_license b
JOIN core.address a USING (address_id)
CROSS JOIN w
WHERE b.application_type = ANY (w.opening_application_types)
  AND b.business_category_code = ANY (w.opening_categories)
  AND coalesce(b.issued_on, b.starts_on) IS NOT NULL;
CREATE INDEX ON opening (license_id);
ANALYZE opening;

-- Every license with an address and a date: the site history to look back through.
CREATE TEMP TABLE site_license AS
SELECT b.license_id, b.account_number, b.business_category_code AS category,
       coalesce(b.issued_on, b.starts_on) AS started_on, b.expires_on,
       a.base_key, a.full_key,
       b.business_category_code = ANY (w.opening_categories) AS is_food
FROM core.business_license b
JOIN core.address a USING (address_id)
CROSS JOIN w
WHERE coalesce(b.issued_on, b.starts_on) IS NOT NULL;
CREATE INDEX ON site_license (full_key, started_on);
CREATE INDEX ON site_license (base_key, started_on);
ANALYZE site_license;

-- Build-out permits with their building. Permit addresses never carry a unit.
CREATE TEMP TABLE buildout AS
SELECT p.permit_id, p.issued_on, p.work_description,
       a.house_number, a.pre_direction, a.street_name
FROM core.permit p
JOIN core.address a USING (address_id)
CROSS JOIN w
WHERE p.permit_category_code = ANY (w.buildout_categories)
  AND p.issued_on IS NOT NULL;
CREATE INDEX ON buildout (street_name, house_number);
ANALYZE buildout;

-- 3. Site class. Checked in order, first hit wins; the most recent earlier license
-- of the winning kind is the prior_license_id. A non-food business at the same
-- premises outranks food elsewhere in the building, as in the profile.
CREATE TEMP TABLE site_class AS
WITH data_start AS (SELECT min(started_on) AS d FROM site_license),
hit AS (
  SELECT o.license_id, o.opened_on,
    sb.license_id AS sb_id, ft.license_id AS ft_id, cp.license_id AS cp_id,
    fb.license_id AS fb_id, cb.license_id AS cb_id
  FROM opening o
  LEFT JOIN LATERAL (
    SELECT s.license_id FROM site_license s
    WHERE s.base_key = o.base_key AND s.account_number = o.account_number
      AND s.started_on < o.opened_on AND s.license_id <> o.license_id
    ORDER BY s.started_on DESC LIMIT 1) sb ON true
  LEFT JOIN LATERAL (
    SELECT s.license_id FROM site_license s
    WHERE s.full_key = o.full_key AND s.is_food AND s.started_on < o.opened_on
    ORDER BY s.started_on DESC LIMIT 1) ft ON true
  LEFT JOIN LATERAL (
    SELECT s.license_id FROM site_license s
    WHERE s.full_key = o.full_key AND NOT s.is_food AND s.started_on < o.opened_on
    ORDER BY s.started_on DESC LIMIT 1) cp ON true
  LEFT JOIN LATERAL (
    SELECT s.license_id FROM site_license s
    WHERE s.base_key = o.base_key AND s.is_food AND s.started_on < o.opened_on
    ORDER BY s.started_on DESC LIMIT 1) fb ON true
  LEFT JOIN LATERAL (
    SELECT s.license_id FROM site_license s
    WHERE s.base_key = o.base_key AND s.started_on < o.opened_on
    ORDER BY s.started_on DESC LIMIT 1) cb ON true
)
SELECT h.license_id, h.opened_on,
  CASE
    WHEN h.sb_id IS NOT NULL THEN 'same_business'
    WHEN h.ft_id IS NOT NULL THEN 'food_takeover'
    WHEN h.cp_id IS NOT NULL THEN 'conversion'
    WHEN h.fb_id IS NOT NULL THEN 'food_in_building'
    WHEN h.cb_id IS NOT NULL THEN 'conversion'
    ELSE 'first_time_site'
  END AS site_class,
  coalesce(h.sb_id, h.ft_id, h.cp_id, h.fb_id, h.cb_id) AS prior_license_id,
  CASE
    WHEN h.sb_id IS NOT NULL THEN 'building'
    WHEN h.ft_id IS NOT NULL OR h.cp_id IS NOT NULL THEN 'premises'
    WHEN h.fb_id IS NOT NULL OR h.cb_id IS NOT NULL THEN 'building'
  END AS matched_at,
  -- Years of license history before the opening: small values mean the class
  -- may be wrong because the history is missing (the early-data effect).
  round(((h.opened_on - ds.d) / 365.25)::numeric, 1) AS history_years
FROM hit h CROSS JOIN data_start ds;
CREATE INDEX ON site_class (license_id);
ANALYZE site_class;

INSERT INTO resolve.license_site_class (license_id, match_run_id, site_class, prior_license_id, evidence)
SELECT c.license_id, r.match_run_id, c.site_class, c.prior_license_id,
       jsonb_strip_nulls(jsonb_build_object(
         'matched_at', c.matched_at,
         'history_years', c.history_years,
         'prior_category', s.category,
         'prior_started_on', s.started_on,
         'prior_expires_on', s.expires_on,
         'prior_account', s.account_number))
FROM site_class c
CROSS JOIN run r
LEFT JOIN site_license s ON s.license_id = c.prior_license_id;

-- 4. Candidate pairs: every build-out permit on the same street and direction,
-- numbered within the opening's range (or equal to its number), issued in the
-- window before the opening. This covers the building key and the range.
CREATE TEMP TABLE pair AS
SELECT o.license_id, p.permit_id,
       o.opened_on - p.issued_on AS days_ahead,
       p.house_number <> o.house_number AS range_other_number,
       p.house_number AS permit_house_number,
       upper(coalesce(p.work_description, '')) ~ w.food_words_pattern AS food_words
FROM opening o
CROSS JOIN w
JOIN buildout p
  ON p.street_name = o.street_name
 AND p.pre_direction IS NOT DISTINCT FROM o.pre_direction
 AND p.house_number BETWEEN o.house_number AND coalesce(o.house_number_high, o.house_number)
 AND p.issued_on BETWEEN o.opened_on - w.window_days_before AND o.opened_on;
CREATE INDEX ON pair (permit_id);
CREATE INDEX ON pair (license_id);
ANALYZE pair;

-- 5. Evidence and score.

-- How many openings compete for each permit.
CREATE TEMP TABLE competition AS
SELECT permit_id, count(*)::int AS candidates
FROM pair
GROUP BY permit_id;
CREATE INDEX ON competition (permit_id);
ANALYZE competition;

-- Best name similarity between the permit's owner or tenant and the license's
-- legal or business name. Applicants and contractors never matched in the profile.
CREATE TEMP TABLE name_match AS
SELECT x.permit_id, x.license_id,
       max(greatest(similarity(pt.name_norm, o.legal_name_norm),
                    similarity(pt.name_norm, coalesce(o.dba_name_norm, ''))))::real AS name_similarity
FROM pair x
JOIN opening o USING (license_id)
JOIN core.permit_party pp ON pp.permit_id = x.permit_id
JOIN core.party pt ON pt.party_id = pp.party_id
CROSS JOIN w
WHERE pp.role = ANY (w.name_roles)
GROUP BY x.permit_id, x.license_id;
CREATE INDEX ON name_match (permit_id, license_id);
ANALYZE name_match;

-- Points per piece of evidence, kept separately so each link shows how it scored.
CREATE TEMP TABLE scored AS
SELECT x.license_id, x.permit_id, x.days_ahead, x.food_words, x.range_other_number,
       x.permit_house_number, c.candidates, n.name_similarity, sc.site_class,
       w.base AS pts_base,
       CASE WHEN x.food_words THEN w.food_words ELSE 0 END AS pts_food_words,
       CASE WHEN n.name_similarity >= w.name_strong_min THEN w.name_strong
            WHEN n.name_similarity >= w.name_weak_min THEN w.name_weak
            ELSE 0 END AS pts_name,
       CASE WHEN c.candidates = 1 THEN w.single_candidate
            WHEN c.candidates >= w.many_candidates_min THEN w.many_candidates
            ELSE 0 END AS pts_candidates,
       CASE WHEN x.days_ahead BETWEEN w.timing_min_days AND w.timing_max_days THEN w.timing
            ELSE 0 END AS pts_timing,
       CASE WHEN sc.site_class IN ('conversion', 'first_time_site') THEN w.class_needs_buildout
            WHEN sc.site_class = 'food_takeover' THEN w.class_food_takeover
            ELSE 0 END AS pts_site_class,
       CASE WHEN x.range_other_number THEN w.range_other_number ELSE 0 END AS pts_range
FROM pair x
CROSS JOIN w
JOIN competition c USING (permit_id)
JOIN site_class sc USING (license_id)
LEFT JOIN name_match n USING (permit_id, license_id);

INSERT INTO resolve.permit_license_link (
  match_run_id, permit_id, license_id, score, decision, address_match,
  name_similarity, distance_m, days_permit_to_license, evidence)
SELECT r.match_run_id, s.permit_id, s.license_id, t.score,
       CASE WHEN t.score >= w.match_min THEN 'match'
            WHEN t.score >= w.possible_min THEN 'possible'
            ELSE 'reject' END,
       'same_building_unit_unknown',
       s.name_similarity, NULL, s.days_ahead,
       jsonb_strip_nulls(jsonb_build_object(
         'food_words', s.food_words,
         'candidates', s.candidates,
         'site_class', s.site_class,
         'permit_house_number', CASE WHEN s.range_other_number THEN s.permit_house_number END,
         'points', jsonb_build_object(
           'base', s.pts_base, 'food_words', s.pts_food_words, 'name', s.pts_name,
           'candidates', s.pts_candidates, 'timing', s.pts_timing,
           'site_class', s.pts_site_class, 'range', s.pts_range)))
FROM scored s
CROSS JOIN run r
CROSS JOIN w
CROSS JOIN LATERAL (
  SELECT least(1, greatest(0, s.pts_base + s.pts_food_words + s.pts_name + s.pts_candidates
                              + s.pts_timing + s.pts_site_class + s.pts_range))::numeric(5, 4) AS score
) t;

-- 6. Close the run.
UPDATE resolve.match_run m
SET finished_at = now()
FROM run r
WHERE m.match_run_id = r.match_run_id;

-- 7. Report.

SELECT 'run' AS report, r.match_run_id,
       (SELECT count(*) FROM opening)::int AS openings,
       (SELECT count(*) FROM opening WHERE application_type = 'relocation')::int AS relocations,
       (SELECT count(*) FROM resolve.license_site_class x WHERE x.match_run_id = r.match_run_id)::int AS site_classes,
       (SELECT count(*) FROM resolve.permit_license_link x WHERE x.match_run_id = r.match_run_id)::int AS links
FROM run r;

SELECT 'site_class_by_year' AS report,
       extract(year FROM opened_on)::int AS year,
       count(*)::int AS openings,
       (count(*) FILTER (WHERE site_class = 'same_business'))::int    AS same_business,
       (count(*) FILTER (WHERE site_class = 'food_takeover'))::int    AS food_takeover,
       (count(*) FILTER (WHERE site_class = 'food_in_building'))::int AS food_in_building,
       (count(*) FILTER (WHERE site_class = 'conversion'))::int       AS conversion,
       (count(*) FILTER (WHERE site_class = 'first_time_site'))::int  AS first_time_site
FROM site_class
GROUP BY 2 ORDER BY 2;

SELECT 'links_by_site_class' AS report, l.evidence ->> 'site_class' AS site_class,
       count(*)::int AS links,
       (count(*) FILTER (WHERE l.decision = 'match'))::int    AS match,
       (count(*) FILTER (WHERE l.decision = 'possible'))::int AS possible,
       (count(*) FILTER (WHERE l.decision = 'reject'))::int   AS reject,
       count(DISTINCT l.license_id) FILTER (WHERE l.decision = 'match')::int AS openings_matched
FROM resolve.permit_license_link l
JOIN run r USING (match_run_id)
GROUP BY 2 ORDER BY links DESC;

SELECT 'score_bands' AS report,
       (floor(l.score * 10) / 10)::numeric(3, 1) AS band_from,
       count(*)::int AS links
FROM resolve.permit_license_link l
JOIN run r USING (match_run_id)
GROUP BY 2 ORDER BY 2;

-- Openings with a full two years of permits before them: the share with a
-- matched build-out, the figure the backtest will build on.
WITH cover AS (
  SELECT min(issued_on) + (SELECT window_days_before FROM w) AS full_from,
         max(issued_on) AS full_through
  FROM core.permit
)
SELECT 'covered_openings' AS report, cv.full_from, cv.full_through,
       count(*)::int AS openings,
       (count(*) FILTER (WHERE EXISTS (
          SELECT 1 FROM resolve.permit_license_link l
          WHERE l.match_run_id = r.match_run_id AND l.license_id = o.license_id
            AND l.decision = 'match')))::int AS with_match,
       (count(*) FILTER (WHERE EXISTS (
          SELECT 1 FROM resolve.permit_license_link l
          WHERE l.match_run_id = r.match_run_id AND l.license_id = o.license_id
            AND l.decision IN ('match', 'possible'))))::int AS with_match_or_possible
FROM opening o
CROSS JOIN cover cv
CROSS JOIN run r
WHERE o.opened_on BETWEEN cv.full_from AND cv.full_through
GROUP BY cv.full_from, cv.full_through;

-- A sample for hand review: up to 10 links from each score band, picked by a
-- hash of the ids so the same run always gives the same sample.
WITH banded AS (
  SELECT l.*, width_bucket(l.score, 0, 1.0001, 5) AS band,
         row_number() OVER (PARTITION BY width_bucket(l.score, 0, 1.0001, 5)
                            ORDER BY md5(l.permit_id::text || '-' || l.license_id::text)) AS pick
  FROM resolve.permit_license_link l
  JOIN run r USING (match_run_id)
)
SELECT 'review_sample' AS report, b.link_id, b.score, b.decision,
       p.permit_number, p.issued_on AS permit_issued, b.days_permit_to_license AS days_ahead,
       left(p.work_description, 60) AS work_description,
       bl.license_id, coalesce(nullif(bl.dba_name, ''), bl.legal_name) AS business,
       bl.address_raw AS license_address,
       b.evidence ->> 'site_class' AS site_class,
       b.evidence ->> 'candidates' AS candidates,
       b.name_similarity
FROM banded b
JOIN core.permit p USING (permit_id)
JOIN core.business_license bl USING (license_id)
WHERE b.pick <= 10
ORDER BY b.score DESC, b.link_id;
