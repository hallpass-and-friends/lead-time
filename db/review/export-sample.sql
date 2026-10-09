-- Read-only. Exports the hand-review sample of one match run as CSV: up to 10
-- links from each fifth of the score range, chosen by a hash of the ids (the
-- same sample the resolver report prints). Columns at the end are left empty
-- for the review.
--
-- Run (PowerShell), setting run to the match_run_id:
--   Get-Content db/review/export-sample.sql | docker compose exec -T db psql -U <user> -d <db> -q --csv -v run=1 > output/review-sample-run1.csv

WITH banded AS (
  SELECT l.*,
         row_number() OVER (PARTITION BY width_bucket(l.score, 0, 1.0001, 5)
                            ORDER BY md5(l.permit_id::text || '-' || l.license_id::text)) AS pick
  FROM resolve.permit_license_link l
  WHERE l.match_run_id = :run
),
names AS (
  SELECT pp.permit_id,
         string_agg(DISTINCT pp.role || ': ' || pt.display_name, ' | ') AS owner_tenant
  FROM core.permit_party pp
  JOIN core.party pt USING (party_id)
  WHERE pp.role IN ('owner', 'tenant')
  GROUP BY pp.permit_id
)
SELECT b.link_id, b.score, b.decision,
       b.evidence ->> 'site_class' AS site_class,
       b.evidence ->> 'candidates' AS candidates,
       (b.evidence ->> 'food_words')::boolean AS food_words,
       round(b.name_similarity::numeric, 2) AS name_similarity,
       p.permit_number, p.permit_type_raw, p.issued_on AS permit_issued,
       b.days_permit_to_license AS days_ahead, p.reported_cost,
       p.address_raw AS permit_address,
       n.owner_tenant,
       p.work_description,
       bl.license_id, bl.legal_name, bl.dba_name, bl.address_raw AS license_address,
       bl.license_type_raw, bl.business_activity_raw,
       coalesce(bl.issued_on, bl.starts_on) AS opened_on,
       '' AS suggested_verdict, '' AS reason, '' AS verdict, '' AS note
FROM banded b
JOIN core.permit p USING (permit_id)
JOIN core.business_license bl USING (license_id)
LEFT JOIN names n ON n.permit_id = b.permit_id
WHERE b.pick <= 10
ORDER BY b.score DESC, b.link_id;
