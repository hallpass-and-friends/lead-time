-- Resolve layer: judgments that link core records. Every judgment belongs to a
-- run, carries a score, and stores the evidence behind it, so matcher versions
-- can be compared and any link can be explained.

CREATE TABLE resolve.match_run (
  match_run_id      bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  jurisdiction_id   smallint NOT NULL REFERENCES ref.jurisdiction,
  algorithm_version text NOT NULL,
  params            jsonb NOT NULL DEFAULT '{}',
  started_at        timestamptz NOT NULL DEFAULT now(),
  finished_at       timestamptz,
  notes             text
);

-- First-time site or takeover. The feasibility check showed these behave very
-- differently: about 47% of first-time food sites had a build-out permit against
-- about 21% of takeovers, so the distinction is stored, not recomputed ad hoc.
CREATE TABLE resolve.license_site_class (
  license_id       bigint NOT NULL REFERENCES core.business_license ON DELETE CASCADE,
  match_run_id     bigint NOT NULL REFERENCES resolve.match_run ON DELETE CASCADE,
  site_class       text NOT NULL CHECK (site_class IN ('first_time_site', 'takeover', 'renewal', 'unknown')),
  prior_license_id bigint REFERENCES core.business_license,
  evidence         jsonb NOT NULL DEFAULT '{}',
  PRIMARY KEY (license_id, match_run_id)
);

-- "This permit was work done for this business." A permit can have several
-- candidate licenses (a strip mall) and a license several permits.
CREATE TABLE resolve.permit_license_link (
  link_id       bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  match_run_id  bigint NOT NULL REFERENCES resolve.match_run ON DELETE CASCADE,
  permit_id     bigint NOT NULL REFERENCES core.permit,
  license_id    bigint NOT NULL REFERENCES core.business_license,
  score         numeric(5, 4) NOT NULL CHECK (score BETWEEN 0 AND 1),
  decision      text NOT NULL CHECK (decision IN ('match', 'possible', 'reject')),
  -- How the two addresses relate is the strongest single piece of evidence, so it
  -- is a column; everything else the matcher looked at goes in evidence.
  address_match text NOT NULL CHECK (address_match IN (
    'same_unit', 'same_building_unit_unknown', 'same_building_other_unit', 'same_parcel', 'nearby')),
  name_similarity real CHECK (name_similarity BETWEEN 0 AND 1),
  distance_m    real CHECK (distance_m >= 0),
  days_permit_to_license integer,
  evidence      jsonb NOT NULL DEFAULT '{}',
  UNIQUE (match_run_id, permit_id, license_id)
);

CREATE INDEX link_license_idx ON resolve.permit_license_link (license_id, match_run_id);
CREATE INDEX link_permit_idx  ON resolve.permit_license_link (permit_id, match_run_id);

-- Hand-checked links. These are the only ground truth for the matcher's own
-- precision, separate from whether a lead later opened.
CREATE TABLE resolve.link_review (
  link_review_id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  link_id     bigint NOT NULL REFERENCES resolve.permit_license_link ON DELETE CASCADE,
  verdict     text NOT NULL CHECK (verdict IN ('confirmed', 'rejected', 'unsure')),
  reviewer    text NOT NULL,
  note        text,
  reviewed_at timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX link_review_link_idx ON resolve.link_review (link_id);
