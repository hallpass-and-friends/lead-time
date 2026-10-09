-- Hand review of the run 1 sample (50 links, 10 per fifth of the score range),
-- reviewed 2026-10-09. Suggested verdicts were written from the work descriptions
-- and licenses, then checked by Rob; 4690, 4053, and 4355 were changed in review.
--
-- confirmed  the permit was work for this opening's business or its space
-- rejected   the permit was work for something else in the building
-- unsure     the records cannot settle it
--
-- Safe to re-run: a link already reviewed by this reviewer is skipped. Stops if
-- any link id is not in match run 1, so the file cannot attach verdicts to the
-- wrong run.
--
-- Run (PowerShell):
--   Get-Content db/review/run1-hand-review.sql | docker compose exec -T db psql -U <user> -d <db> -v ON_ERROR_STOP=1 --single-transaction

CREATE TEMP TABLE verdict (link_id bigint PRIMARY KEY, verdict text NOT NULL, note text NOT NULL);

INSERT INTO verdict (link_id, verdict, note) VALUES
  ( 688, 'confirmed', 'Build-out for new Pollo Campero at this address; owner is the licensee'),
  ( 813, 'confirmed', 'Kitchen work at the existing restaurant; tenant Halsted Deli LLC is the licensee (small job, 18 days ahead)'),
  (4935, 'confirmed', 'Build-out of a new Starbucks drive-thru; owner name matches'),
  (5926, 'confirmed', 'Alteration of the cafe space; tenant is the licensee'),
  (4690, 'confirmed', 'Owner is the licensee, work is level 1 of its own building, cafe opened 147 days later; original permit 100854995 is from before 2021 (not loaded)'),
  (1008, 'confirmed', 'Tenant build-out for a grocery store 49 days before the opening'),
  (1631, 'confirmed', 'Build-out of a coffee shop space at this address'),
  (4339, 'confirmed', 'New one-story building for a single cafe tenant selling coffee'),
  (6021, 'confirmed', 'New convenience store; owner RDK Ventures is the licensee (Circle K)'),
  (2253, 'rejected', 'Library renovation on the 5th floor; the license DBA is the school name, so the name matched'),
  ( 826, 'confirmed', 'Conversion of an Au Bon Pain to a new Panera Bread'),
  ( 947, 'confirmed', 'Alterations to the ground-floor restaurant; owner is Gordon Ramsay North America'),
  (1752, 'confirmed', 'Alterations to the lower-level cafe; the license is on the lower level'),
  ( 225, 'confirmed', 'Remodel of the existing restaurant with a new bar at this address'),
  ( 788, 'confirmed', 'Converts tenant space CO-1 to a coffee shop; the license is unit C01'),
  (1233, 'confirmed', 'First-time build-out of a catering kitchen; the licensee is Green Street Kitchen'),
  (4053, 'unsure', 'All four openings competing for this permit are food businesses, so it could be any of them'),
  (  23, 'confirmed', 'New ice cream place; missed because ICE CREAM is not a food word'),
  ( 138, 'rejected', 'Office and HR suite on the 25th floor'),
  (2945, 'rejected', 'Build-out is for a bakery in suite 106A; the license is Tin Roof in C102-103'),
  (3704, 'confirmed', 'Build-out of space 571 at O''Hare T5 for the new tenant Protein Bar; the name is in the description'),
  (4520, 'rejected', 'Alterations for a different restaurant (owner Chef Art Smith Navy LLC), not Ciccio'),
  (4963, 'rejected', 'Office renovation on the 31st floor; the license is on the 48th'),
  (5861, 'rejected', 'Temporary event truss (ERECTION STARTS), not a build-out'),
  ( 333, 'confirmed', 'Re-image of this Burger King; the business name is in the description'),
  (1517, 'rejected', 'Temporary parade stage (ERECTION STARTS)'),
  (2847, 'confirmed', 'Alterations to the existing restaurant building and storefront; RESTURANT is misspelled, so no food word'),
  (4450, 'rejected', 'Temporary street-fest stage (ERECTION STARTS)'),
  (1328, 'rejected', 'Stair infill between the 25th and 26th floors'),
  (2821, 'rejected', 'Temporary mobile stage (ERECTION STARTS)'),
  (1876, 'rejected', 'IDF (network) rooms on levels 7 to 9'),
  (4486, 'rejected', 'Office partitions on the 15th floor'),
  (4429, 'rejected', 'Restrooms on the 6th floor'),
  (4944, 'rejected', 'Temporary NeoCon tent'),
  (1662, 'rejected', 'Equipment room build-out for Verizon'),
  (2846, 'rejected', 'Airport LED signs'),
  (4355, 'rejected', 'Midway space CB-04 does not look like the license''s space 17-226'),
  (5135, 'rejected', 'Air cargo facility shell'),
  (4805, 'rejected', 'LOT Polish Airlines lounge, not this business'),
  (5941, 'rejected', 'Steel for an amusement ride at Navy Pier'),
  ( 490, 'rejected', 'Terminal 1 tunnel structural repairs'),
  (1436, 'rejected', 'Terminal 3 electrical work; the license is Terminal 5'),
  (1905, 'rejected', 'Corridor on the 39th floor'),
  (2276, 'rejected', 'Rooftop solar panels'),
  (2496, 'rejected', 'Baggage screening office'),
  (3673, 'rejected', 'Airport LED signs'),
  (4046, 'rejected', 'Air handling units between Terminals 2 and 3'),
  (5257, 'rejected', 'Revision to the rooftop solar layout'),
  (5573, 'unsure', 'O''Hare retail space alteration, unit not given; the license is T5 520 (639 days ahead)'),
  (5192, 'rejected', 'Office suites on the 12th floor');

DO $$
DECLARE missing int;
BEGIN
  SELECT count(*) INTO missing
  FROM verdict v
  WHERE NOT EXISTS (
    SELECT 1 FROM resolve.permit_license_link l
    WHERE l.link_id = v.link_id AND l.match_run_id = 1);
  IF missing > 0 THEN
    RAISE EXCEPTION '% reviewed link ids are not in match run 1', missing;
  END IF;
END $$;

INSERT INTO resolve.link_review (link_id, verdict, reviewer, note)
SELECT v.link_id, v.verdict, 'rob', v.note
FROM verdict v
WHERE NOT EXISTS (
  SELECT 1 FROM resolve.link_review r
  WHERE r.link_id = v.link_id AND r.reviewer = 'rob');

-- Report: verdicts by the resolver's decision. Precision counts unsure as
-- neither right nor wrong. The sample takes 10 links per fifth of the score
-- range, so these are per-decision figures, not an estimate for all links.
SELECT l.decision, count(*) AS reviewed,
       count(*) FILTER (WHERE r.verdict = 'confirmed') AS confirmed,
       count(*) FILTER (WHERE r.verdict = 'rejected')  AS rejected,
       count(*) FILTER (WHERE r.verdict = 'unsure')    AS unsure,
       round(100.0 * count(*) FILTER (WHERE r.verdict = 'confirmed')
             / nullif(count(*) FILTER (WHERE r.verdict <> 'unsure'), 0), 1) AS pct_confirmed_of_decided
FROM resolve.link_review r
JOIN resolve.permit_license_link l USING (link_id)
WHERE l.match_run_id = 1 AND r.reviewer = 'rob'
GROUP BY l.decision
ORDER BY min(l.score) DESC;
