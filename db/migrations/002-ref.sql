-- Lookup tables. These are tables instead of CHECK lists because every new city
-- adds values, and adding a row is safer than altering a constraint.

CREATE TABLE ref.jurisdiction (
  jurisdiction_id smallint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  code            text NOT NULL UNIQUE CHECK (code ~ '^[a-z0-9-]+$'),
  name            text NOT NULL,
  state_code      char(2) NOT NULL,
  -- Source dates are local wall-clock dates; the zone is needed to compare across cities.
  time_zone       text NOT NULL
);

CREATE TABLE ref.source (
  source_id        smallint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  jurisdiction_id  smallint NOT NULL REFERENCES ref.jurisdiction,
  code             text NOT NULL UNIQUE CHECK (code ~ '^[a-z0-9-]+$'),
  name             text NOT NULL,
  record_kind      text NOT NULL CHECK (record_kind IN ('permit', 'business_license', 'inspection', 'liquor_license')),
  provider         text NOT NULL,
  external_id      text,
  endpoint_url     text NOT NULL,
  -- Reuse terms differ per publisher and are a product risk, so they are recorded
  -- next to the source and dated, not left in a README.
  reuse_terms      text,
  reuse_terms_url  text,
  reuse_terms_checked_on date
);

CREATE TABLE ref.permit_category (
  code      text PRIMARY KEY CHECK (code ~ '^[a-z_]+$'),
  name      text NOT NULL,
  -- True when this kind of permit tends to precede vendor selection.
  is_early_signal boolean NOT NULL DEFAULT false
);

CREATE TABLE ref.business_category (
  code text PRIMARY KEY CHECK (code ~ '^[a-z_]+$'),
  name text NOT NULL
);

CREATE TABLE ref.signal_type (
  code text PRIMARY KEY CHECK (code ~ '^[a-z_]+$'),
  name text NOT NULL
);
