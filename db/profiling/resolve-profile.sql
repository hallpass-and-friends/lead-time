-- Read-only profile for the Resolve phase. Changes nothing in the database:
-- it only builds temp tables, which disappear when the session ends.
-- Answers the questions the Resolve design depends on:
--   A. What does the opening cohort look like, and which license date is the opening?
--   B. How often does a new food license follow an earlier business at the same place?
--   C. How long after the previous food business does a takeover open?
--   D. Which permits land near a new license at the same building, and how far ahead?
--      D3 compares build-out rates with food businesses that were not opening.
--   E. When a permit matches the building, how many new licenses compete for it?
--   F. Do permit party names help pick the right license?
--   G. Do permit work descriptions mention food work?
--   H. Do range addresses ("5300-5304") hide permits at the other numbers?
-- Sections D to H use only openings with permit data for the whole window around
-- them (see permit_cover), because permits are loaded from a later year than licenses.

\pset pager off
\timing on

-- The opening cohort: new food licenses with a parsed address. Liquor is left out
-- because a liquor license usually rides along with a restaurant that is already
-- in the cohort. opened_on is the issue date (the day the business may open), with
-- the license start as a fallback; section A shows how far apart the two are.
CREATE TEMP TABLE cohort AS
SELECT b.license_id, b.account_number, b.site_number, b.business_category_code AS category,
       b.legal_name_norm, b.dba_name_norm,
       coalesce(b.issued_on, b.starts_on) AS opened_on, b.issued_on, b.starts_on,
       a.address_id, a.base_key, a.full_key,
       a.house_number, a.house_number_high, a.pre_direction, a.street_name,
       (a.floor IS NOT NULL OR a.unit IS NOT NULL) AS has_unit
FROM core.business_license b
JOIN core.address a USING (address_id)
WHERE b.application_type = 'new'
  AND b.business_category_code IN ('restaurant', 'food_retail', 'food_unclassified', 'bar')
  AND coalesce(b.issued_on, b.starts_on) IS NOT NULL;
CREATE INDEX ON cohort (base_key);
ANALYZE cohort;

-- Every license with an address and a date, for site history. One row per license.
CREATE TEMP TABLE site_license AS
SELECT b.license_id, b.account_number, b.business_category_code AS category,
       coalesce(b.issued_on, b.starts_on) AS started_on, b.expires_on,
       a.base_key, a.full_key
FROM core.business_license b
JOIN core.address a USING (address_id)
WHERE coalesce(b.issued_on, b.starts_on) IS NOT NULL;
CREATE INDEX ON site_license (full_key);
CREATE INDEX ON site_license (base_key);
ANALYZE site_license;

-- Permits with a building key. Permit addresses never carry a unit, so the
-- building is the finest level a permit can be matched at.
CREATE TEMP TABLE site_permit AS
SELECT p.permit_id, p.permit_category_code AS category, p.issued_on, p.applied_on,
       p.work_description, a.base_key, a.house_number, a.pre_direction, a.street_name
FROM core.permit p
JOIN core.address a USING (address_id)
WHERE p.issued_on IS NOT NULL;
CREATE INDEX ON site_permit (base_key);
CREATE INDEX ON site_permit (street_name, house_number);
ANALYZE site_permit;

-- The dates with permit data on both sides of an opening: two years of permits
-- before it and 90 days after. Taken from the data rather than typed in, so it
-- stays right if more permit years are loaded.
CREATE TEMP TABLE permit_cover AS
SELECT min(issued_on) + 730 AS full_from, max(issued_on) - 90 AS full_through
FROM site_permit;

-- The openings sections D to H may use.
CREATE TEMP TABLE pcohort AS
SELECT c.*
FROM cohort c, permit_cover pc
WHERE c.opened_on BETWEEN pc.full_from AND pc.full_through;
CREATE INDEX ON pcohort (license_id);
ANALYZE pcohort;

\echo
\echo === A. Cohort by year: size, units, and issue-to-start gap ===
-- The license data has a first year; openings near it have no visible history,
-- so their "first-time site" share will be inflated. Look for where the share settles.
SELECT 'A_cohort' AS report,
       extract(year FROM opened_on)::int AS year,
       count(*) AS licenses,
       count(*) FILTER (WHERE category = 'restaurant') AS restaurant,
       count(*) FILTER (WHERE category = 'food_retail') AS food_retail,
       count(*) FILTER (WHERE category = 'food_unclassified') AS food_unclassified,
       count(*) FILTER (WHERE category = 'bar') AS bar,
       round(100.0 * count(*) FILTER (WHERE has_unit) / count(*), 1) AS pct_with_unit,
       percentile_disc(0.5) WITHIN GROUP (ORDER BY starts_on - issued_on) AS median_start_minus_issue_days
FROM cohort
GROUP BY 2 ORDER BY 2;

-- Site history: what was at the same place before each cohort license.
-- Checked in order, first hit wins:
--   same_account   the same account already had a license here (not a new business)
--   food_same_unit an earlier food business at the same premises (takeover)
--   other_same_unit an earlier non-food business at the same premises
--   building_food  nothing at this premises, but an earlier food license elsewhere
--                  in the building (or the same premises written differently)
--   building_other nothing at this premises, only earlier non-food licenses in the building
--   none           nothing earlier at the building (first-time site)
CREATE TEMP TABLE history AS
SELECT c.license_id, c.opened_on, c.has_unit,
  CASE
    WHEN EXISTS (SELECT 1 FROM site_license s
                 WHERE s.base_key = c.base_key AND s.account_number = c.account_number
                   AND s.started_on < c.opened_on AND s.license_id <> c.license_id)
      THEN 'same_account'
    WHEN EXISTS (SELECT 1 FROM site_license s
                 WHERE s.full_key = c.full_key AND s.started_on < c.opened_on
                   AND s.category IN ('restaurant', 'food_retail', 'food_unclassified', 'bar'))
      THEN 'food_same_unit'
    WHEN EXISTS (SELECT 1 FROM site_license s
                 WHERE s.full_key = c.full_key AND s.started_on < c.opened_on)
      THEN 'other_same_unit'
    WHEN EXISTS (SELECT 1 FROM site_license s
                 WHERE s.base_key = c.base_key AND s.started_on < c.opened_on
                   AND s.category IN ('restaurant', 'food_retail', 'food_unclassified', 'bar'))
      THEN 'building_food'
    WHEN EXISTS (SELECT 1 FROM site_license s
                 WHERE s.base_key = c.base_key AND s.started_on < c.opened_on)
      THEN 'building_other'
    ELSE 'none'
  END AS history
FROM cohort c;
ANALYZE history;

\echo
\echo === B. Site history by year (percent of cohort) ===
SELECT 'B_history' AS report,
       extract(year FROM opened_on)::int AS year,
       count(*) AS licenses,
       round(100.0 * count(*) FILTER (WHERE history = 'same_account')    / count(*), 1) AS same_account,
       round(100.0 * count(*) FILTER (WHERE history = 'food_same_unit')  / count(*), 1) AS food_same_unit,
       round(100.0 * count(*) FILTER (WHERE history = 'other_same_unit') / count(*), 1) AS other_same_unit,
       round(100.0 * count(*) FILTER (WHERE history = 'building_food')   / count(*), 1) AS building_food,
       round(100.0 * count(*) FILTER (WHERE history = 'building_other')  / count(*), 1) AS building_other,
       round(100.0 * count(*) FILTER (WHERE history = 'none')            / count(*), 1) AS none
FROM history
GROUP BY 2 ORDER BY 2;

\echo
\echo === B2. Site history split by whether the cohort address has a unit (all years) ===
-- A building-only address cannot tell its own tenant from its neighbors, so
-- "building_food" there may really be a takeover.
SELECT 'B2_history_by_unit' AS report, has_unit, history, count(*) AS licenses,
       round(100.0 * count(*) / sum(count(*)) OVER (PARTITION BY has_unit), 1) AS pct
FROM history
GROUP BY has_unit, history ORDER BY has_unit, licenses DESC;

\echo
\echo === C. Takeovers: days from the last earlier food license expiring to the new opening ===
-- Negative means the old license had not expired yet when the new one was issued.
WITH gap AS (
  SELECT c.license_id,
         c.opened_on - max(s.expires_on) AS days
  FROM cohort c
  JOIN history h USING (license_id)
  JOIN site_license s ON s.full_key = c.full_key AND s.started_on < c.opened_on
   AND s.category IN ('restaurant', 'food_retail', 'food_unclassified', 'bar')
  WHERE h.history = 'food_same_unit' AND s.expires_on IS NOT NULL
  GROUP BY c.license_id, c.opened_on
)
SELECT 'C_takeover_gap' AS report, count(*) AS takeovers,
       count(*) FILTER (WHERE days < 0) AS overlapping,
       percentile_disc(array[0.1, 0.25, 0.5, 0.75, 0.9]) WITHIN GROUP (ORDER BY days) AS p10_p25_p50_p75_p90_days
FROM gap;

-- Candidate pairs: every permit at the opening's building issued from two years
-- before the opening to 90 days after it. Wide on purpose; sections D and E show
-- where the real window should be. Only openings with full permit coverage.
CREATE TEMP TABLE pair AS
SELECT c.license_id, p.permit_id, p.category AS permit_category,
       c.opened_on - p.issued_on AS days_ahead
FROM pcohort c
JOIN site_permit p ON p.base_key = c.base_key
WHERE p.issued_on BETWEEN c.opened_on - 730 AND c.opened_on + 90;
CREATE INDEX ON pair (permit_id);
CREATE INDEX ON pair (license_id);
ANALYZE pair;

\echo
\echo === D0. Openings with permit data for the whole window (used by D to H) ===
SELECT 'D0_permit_cover' AS report, pc.full_from, pc.full_through,
       (SELECT count(*) FROM pcohort) AS openings,
       (SELECT count(*) FROM cohort) AS all_openings
FROM permit_cover pc;

\echo
\echo === D. Permits near an opening, by permit category ===
-- days_ahead is opening minus permit issue: positive means the permit came first.
SELECT 'D_permit_window' AS report, permit_category,
       count(*) AS pairs,
       count(DISTINCT license_id) AS licenses_with_one,
       round(100.0 * count(DISTINCT license_id) / (SELECT count(*) FROM pcohort), 1) AS pct_of_openings,
       percentile_disc(array[0.1, 0.25, 0.5, 0.75, 0.9]) WITHIN GROUP (ORDER BY days_ahead) AS p10_p25_p50_p75_p90_days_ahead
FROM pair
GROUP BY permit_category ORDER BY pairs DESC;

\echo
\echo === D2. Renovation or new-construction permit before opening, by site history ===
-- Reproduces the feasibility finding (first-time sites need build-outs more often).
SELECT 'D2_buildout_by_history' AS report, h.history,
       count(*) AS licenses,
       count(*) FILTER (WHERE EXISTS (
         SELECT 1 FROM pair x
         WHERE x.license_id = h.license_id AND x.days_ahead > 0
           AND x.permit_category IN ('renovation', 'new_construction'))) AS with_buildout,
       round(100.0 * count(*) FILTER (WHERE EXISTS (
         SELECT 1 FROM pair x
         WHERE x.license_id = h.license_id AND x.days_ahead > 0
           AND x.permit_category IN ('renovation', 'new_construction'))) / count(*), 1) AS pct
FROM history h
JOIN pcohort USING (license_id)
GROUP BY h.history ORDER BY licenses DESC;

-- Baseline: food businesses that were renewing, not opening, in the same dates.
-- One row per business and building (its first renewal in the window), and only
-- buildings with no opening from two years before to 90 days after, so the
-- permits counted cannot belong to an opening.
CREATE TEMP TABLE baseline AS
SELECT DISTINCT ON (b.account_number, a.base_key)
       b.license_id, coalesce(b.issued_on, b.starts_on) AS ref_on, a.base_key
FROM core.business_license b
JOIN core.address a USING (address_id)
CROSS JOIN permit_cover pc
WHERE b.application_type = 'renewal'
  AND b.business_category_code IN ('restaurant', 'food_retail', 'food_unclassified', 'bar')
  AND coalesce(b.issued_on, b.starts_on) BETWEEN pc.full_from AND pc.full_through
  AND NOT EXISTS (
    SELECT 1 FROM cohort c
    WHERE c.base_key = a.base_key
      AND c.opened_on BETWEEN coalesce(b.issued_on, b.starts_on) - 730
                          AND coalesce(b.issued_on, b.starts_on) + 90)
ORDER BY b.account_number, a.base_key, coalesce(b.issued_on, b.starts_on);
ANALYZE baseline;

\echo
\echo === D3. Build-out permit in the two years before: openings vs renewing food businesses ===
WITH buildout AS (
  SELECT 'opening' AS grp, c.license_id,
         EXISTS (SELECT 1 FROM site_permit p
                 WHERE p.base_key = c.base_key
                   AND p.category IN ('renovation', 'new_construction')
                   AND p.issued_on BETWEEN c.opened_on - 730 AND c.opened_on - 1) AS has_buildout
  FROM pcohort c
  UNION ALL
  SELECT 'renewing (baseline)', b.license_id,
         EXISTS (SELECT 1 FROM site_permit p
                 WHERE p.base_key = b.base_key
                   AND p.category IN ('renovation', 'new_construction')
                   AND p.issued_on BETWEEN b.ref_on - 730 AND b.ref_on - 1)
  FROM baseline b
)
SELECT 'D3_buildout_vs_baseline' AS report, grp AS "group",
       count(*) AS businesses,
       count(*) FILTER (WHERE has_buildout) AS with_buildout,
       round(100.0 * count(*) FILTER (WHERE has_buildout) / count(*), 1) AS pct
FROM buildout
GROUP BY grp ORDER BY grp;

\echo
\echo === E. Build-out permits: how many cohort licenses compete for each one ===
SELECT 'E_candidates_per_permit' AS report,
       CASE WHEN n >= 5 THEN '5+' ELSE n::text END AS candidate_licenses,
       count(*) AS permits
FROM (
  SELECT permit_id, count(*) AS n
  FROM pair
  WHERE permit_category IN ('renovation', 'new_construction')
  GROUP BY permit_id
) t
GROUP BY 2 ORDER BY min(n);

\echo
\echo === F. Best name similarity between a permit party and the license (build-out pairs) ===
-- Compares every party on the permit to both the legal name and the DBA.
WITH best AS (
  SELECT x.license_id, x.permit_id,
         count(pt.party_id) AS parties,
         max(greatest(similarity(pt.name_norm, c.legal_name_norm),
                      coalesce(similarity(pt.name_norm, c.dba_name_norm), 0))) AS sim,
         (array_agg(pp.role ORDER BY greatest(similarity(pt.name_norm, c.legal_name_norm),
                      coalesce(similarity(pt.name_norm, c.dba_name_norm), 0)) DESC))[1] AS best_role
  FROM pair x
  JOIN pcohort c USING (license_id)
  LEFT JOIN core.permit_party pp ON pp.permit_id = x.permit_id
  LEFT JOIN core.party pt ON pt.party_id = pp.party_id
  WHERE x.permit_category IN ('renovation', 'new_construction')
  GROUP BY x.license_id, x.permit_id
)
SELECT 'F_name_similarity' AS report,
       CASE WHEN parties = 0 THEN 'no parties'
            WHEN sim >= 0.6 THEN '>= 0.6'
            WHEN sim >= 0.4 THEN '0.4 - 0.6'
            ELSE '< 0.4' END AS bucket,
       count(*) AS pairs,
       count(*) FILTER (WHERE best_role = 'owner') AS best_is_owner,
       count(*) FILTER (WHERE best_role = 'applicant') AS best_is_applicant,
       count(*) FILTER (WHERE best_role = 'contractor') AS best_is_contractor
FROM best
GROUP BY 2 ORDER BY min(CASE WHEN parties = 0 THEN -1 ELSE sim END) DESC;

\echo
\echo === G. Food words in work descriptions: build-out pairs vs all build-out permits ===
WITH food_words AS (
  SELECT '\m(RESTAURANT|KITCHEN|HOOD|GREASE|CAFE|COFFEE|BAKERY|BAR|TAVERN|FOOD|DINING|PIZZA|GROCERY|DELI)\M'::text AS pattern
)
SELECT 'G_food_words' AS report, scope, count(*) AS permits,
       count(*) FILTER (WHERE upper(work_description) ~ (SELECT pattern FROM food_words)) AS with_food_word,
       round(100.0 * count(*) FILTER (WHERE upper(work_description) ~ (SELECT pattern FROM food_words)) / count(*), 1) AS pct
FROM (
  SELECT 'paired with an opening' AS scope, p.work_description
  FROM site_permit p
  WHERE p.category IN ('renovation', 'new_construction')
    AND p.permit_id IN (SELECT permit_id FROM pair WHERE days_ahead > 0)
  UNION ALL
  SELECT 'all build-out permits', p.work_description
  FROM site_permit p
  WHERE p.category IN ('renovation', 'new_construction')
) t
GROUP BY scope;

\echo
\echo === H. Range addresses: build-out permits at the other numbers in the range ===
-- base_key keeps only the low number, so a permit filed at 5304 is invisible to
-- a license at 5300-5304. Counts licenses that would gain a permit if the whole
-- range were searched.
SELECT 'H_range_addresses' AS report,
       count(*) AS range_licenses,
       count(*) FILTER (WHERE EXISTS (
         SELECT 1 FROM pair x
         WHERE x.license_id = c.license_id AND x.days_ahead > 0
           AND x.permit_category IN ('renovation', 'new_construction'))) AS buildout_at_low_number,
       count(*) FILTER (WHERE EXISTS (
         SELECT 1 FROM site_permit p
         WHERE p.street_name = c.street_name
           AND p.pre_direction IS NOT DISTINCT FROM c.pre_direction
           AND p.house_number > c.house_number AND p.house_number <= c.house_number_high
           AND p.category IN ('renovation', 'new_construction')
           AND p.issued_on BETWEEN c.opened_on - 730 AND c.opened_on)) AS buildout_at_other_numbers
FROM pcohort c
WHERE c.house_number_high IS NOT NULL;
