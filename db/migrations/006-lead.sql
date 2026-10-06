-- Lead layer: dated signals at an address, leads scored from them as of a given
-- day, and what actually happened afterwards.

CREATE TABLE lead.signal (
  signal_id        bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  jurisdiction_id  smallint NOT NULL REFERENCES ref.jurisdiction,
  address_id       bigint NOT NULL REFERENCES core.address,
  signal_type_code text NOT NULL REFERENCES ref.signal_type,
  -- The day the signal became public. A score run may only use signals observed
  -- on or before its as_of date; that rule is what keeps a backtest honest.
  observed_on      date NOT NULL,
  permit_id        bigint REFERENCES core.permit,
  license_id       bigint REFERENCES core.business_license,
  details          jsonb NOT NULL DEFAULT '{}',
  -- Exactly one source row, so every signal traces back to a raw record.
  CHECK (num_nonnulls(permit_id, license_id) = 1)
);

CREATE UNIQUE INDEX signal_permit_uq  ON lead.signal (signal_type_code, permit_id)  WHERE permit_id IS NOT NULL;
CREATE UNIQUE INDEX signal_license_uq ON lead.signal (signal_type_code, license_id) WHERE license_id IS NOT NULL;
CREATE INDEX signal_address_idx ON lead.signal (address_id, observed_on);

CREATE TABLE lead.score_run (
  score_run_id    bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  jurisdiction_id smallint NOT NULL REFERENCES ref.jurisdiction,
  model_version   text NOT NULL,
  -- The run pretends today is as_of. For a live run it is the run date.
  as_of           date NOT NULL,
  -- How long after as_of an opening still counts as predicted.
  horizon_days    integer NOT NULL DEFAULT 365 CHECK (horizon_days > 0),
  params          jsonb NOT NULL DEFAULT '{}',
  created_at      timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE lead.lead (
  lead_id         bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  score_run_id    bigint NOT NULL REFERENCES lead.score_run ON DELETE CASCADE,
  address_id      bigint NOT NULL REFERENCES core.address,
  predicted_category_code text NOT NULL REFERENCES ref.business_category,
  score           numeric(5, 4) NOT NULL CHECK (score BETWEEN 0 AND 1),
  first_signal_on date NOT NULL,
  last_signal_on  date NOT NULL,
  -- A short human-readable account of why the lead exists, for the review screen.
  explanation     jsonb NOT NULL DEFAULT '{}',
  UNIQUE (score_run_id, address_id, predicted_category_code),
  CHECK (last_signal_on >= first_signal_on)
);

CREATE INDEX lead_score_idx ON lead.lead (score_run_id, score DESC);

CREATE TABLE lead.lead_signal (
  lead_id      bigint NOT NULL REFERENCES lead.lead ON DELETE CASCADE,
  signal_id    bigint NOT NULL REFERENCES lead.signal,
  contribution numeric(6, 4),
  PRIMARY KEY (lead_id, signal_id)
);

-- What happened to a lead. Filled in only for backtest runs, or later for live ones.
CREATE TABLE lead.outcome (
  lead_id      bigint PRIMARY KEY REFERENCES lead.lead ON DELETE CASCADE,
  outcome      text NOT NULL CHECK (outcome IN ('opened', 'not_opened')),
  license_id   bigint REFERENCES core.business_license,
  opened_on    date,
  evaluated_at timestamptz NOT NULL DEFAULT now(),
  CHECK ((outcome = 'opened') = (license_id IS NOT NULL AND opened_on IS NOT NULL))
);

CREATE INDEX outcome_license_idx ON lead.outcome (license_id) WHERE license_id IS NOT NULL;

-- Headline numbers per backtest run: precision, recall, and median lead time.
-- Recall is measured against every new license of a predicted category that
-- started inside the run's horizon, whether or not a lead existed for it.
CREATE VIEW lead.backtest_summary AS
WITH lead_stats AS (
  SELECT
    l.score_run_id,
    count(*)                                         AS leads,
    count(*) FILTER (WHERE o.outcome = 'opened')     AS leads_opened,
    count(o.lead_id)                                 AS leads_evaluated,
    count(DISTINCT o.license_id)                     AS openings_caught,
    percentile_cont(0.5) WITHIN GROUP (ORDER BY o.opened_on - l.first_signal_on)
      FILTER (WHERE o.outcome = 'opened')            AS median_lead_days
  FROM lead.lead l
  LEFT JOIN lead.outcome o USING (lead_id)
  GROUP BY l.score_run_id
),
eligible AS (
  SELECT r.score_run_id, count(*) AS openings
  FROM lead.score_run r
  JOIN core.business_license b
    ON  b.jurisdiction_id = r.jurisdiction_id
    AND b.application_type = 'new'
    AND b.starts_on >  r.as_of
    AND b.starts_on <= r.as_of + r.horizon_days
  WHERE b.business_category_code IN (
    SELECT l.predicted_category_code FROM lead.lead l WHERE l.score_run_id = r.score_run_id)
  GROUP BY r.score_run_id
)
SELECT
  r.score_run_id,
  r.model_version,
  r.as_of,
  r.horizon_days,
  coalesce(s.leads, 0)           AS leads,
  coalesce(s.leads_opened, 0)    AS leads_opened,
  coalesce(e.openings, 0)        AS openings,
  coalesce(s.openings_caught, 0) AS openings_caught,
  round(s.leads_opened::numeric    / nullif(s.leads_evaluated, 0), 4) AS precision,
  round(s.openings_caught::numeric / nullif(e.openings, 0), 4)        AS recall,
  s.median_lead_days
FROM lead.score_run r
LEFT JOIN lead_stats s USING (score_run_id)
LEFT JOIN eligible   e USING (score_run_id);
