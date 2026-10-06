-- Core layer: one common shape for addresses, parties, permits, and licenses,
-- whatever the source city calls its columns.

-- Names are compared after removing the differences that carry no meaning:
-- case, punctuation, and a trailing legal-form word (LLC, INC, ...).
-- Apostrophes are deleted, not spaced, so JOE'S and JOES normalize the same.
CREATE FUNCTION core.normalize_name(name text) RETURNS text
LANGUAGE sql IMMUTABLE PARALLEL SAFE RETURNS NULL ON NULL INPUT
RETURN nullif(
  btrim(regexp_replace(
    regexp_replace(
      btrim(regexp_replace(replace(regexp_replace(upper(name), '[''’`]', '', 'g'), '&', ' AND '), '[^A-Z0-9]+', ' ', 'g')),
      '( (LLC|L L C|INC|INCORPORATED|CORP|CORPORATION|CO|COMPANY|LTD|LP|LLP))+$', ''),
    ' +', ' ', 'g')),
  '');

CREATE TABLE core.address (
  address_id      bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  jurisdiction_id smallint NOT NULL REFERENCES ref.jurisdiction,
  house_number    integer NOT NULL,
  -- Upper end when the source gives a range such as 2258-2260.
  house_number_high integer,
  pre_direction   text,
  street_name     text NOT NULL,
  street_type     text,
  post_direction  text,
  unit            text,
  postal_code     text,
  parcel_id       text,
  geog            geography(Point, 4326),
  -- Two keys because permits usually omit the suite and licenses usually include it.
  -- base_key finds every record in the building; full_key identifies one premises.
  base_key text GENERATED ALWAYS AS (
    house_number::text
    || coalesce(' ' || pre_direction, '')
    || ' ' || street_name
    || coalesce(' ' || street_type, '')
    || coalesce(' ' || post_direction, '')
  ) STORED,
  full_key text GENERATED ALWAYS AS (
    house_number::text
    || coalesce(' ' || pre_direction, '')
    || ' ' || street_name
    || coalesce(' ' || street_type, '')
    || coalesce(' ' || post_direction, '')
    || coalesce(' #' || unit, '')
  ) STORED,
  UNIQUE (jurisdiction_id, full_key),
  CHECK (house_number_high IS NULL OR house_number_high >= house_number),
  -- The pipeline writes these parts already upper-cased and trimmed; the check
  -- stops a second code path from creating near-duplicate addresses.
  CHECK (street_name = upper(btrim(street_name)))
);

CREATE INDEX address_base_idx   ON core.address (jurisdiction_id, base_key);
CREATE INDEX address_parcel_idx ON core.address (jurisdiction_id, parcel_id) WHERE parcel_id IS NOT NULL;
CREATE INDEX address_geog_idx   ON core.address USING gist (geog);

-- A party is a distinct normalized name within a jurisdiction. Deciding that two
-- different names are the same party is a resolve-layer judgment, not a core fact.
CREATE TABLE core.party (
  party_id        bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  jurisdiction_id smallint NOT NULL REFERENCES ref.jurisdiction,
  display_name    text NOT NULL,
  name_norm       text GENERATED ALWAYS AS (core.normalize_name(display_name)) STORED,
  party_kind      text NOT NULL DEFAULT 'unknown' CHECK (party_kind IN ('person', 'organization', 'unknown')),
  UNIQUE (jurisdiction_id, name_norm)
);

CREATE INDEX party_name_trgm_idx ON core.party USING gin (name_norm gin_trgm_ops);

CREATE TABLE core.permit (
  permit_id       bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  record_id       bigint NOT NULL REFERENCES raw.record,
  source_id       smallint NOT NULL REFERENCES ref.source,
  jurisdiction_id smallint NOT NULL REFERENCES ref.jurisdiction,
  permit_number   text NOT NULL,
  -- Null when the address could not be parsed; address_raw keeps what the source said.
  address_id      bigint REFERENCES core.address,
  address_raw     text NOT NULL,
  permit_type_raw text,
  permit_category_code text NOT NULL REFERENCES ref.permit_category,
  work_description text,
  -- applied_on is the earliest public trace and drives lead time; issued_on can be months later.
  applied_on      date,
  issued_on       date,
  reported_cost   numeric(14, 2),
  status_raw      text,
  UNIQUE (source_id, permit_number),
  CHECK (applied_on IS NOT NULL OR issued_on IS NOT NULL)
);

CREATE INDEX permit_address_idx ON core.permit (address_id);
CREATE INDEX permit_applied_idx ON core.permit (jurisdiction_id, applied_on);
CREATE INDEX permit_work_fts_idx ON core.permit USING gin (to_tsvector('english', coalesce(work_description, '')));

CREATE TABLE core.permit_party (
  permit_id bigint NOT NULL REFERENCES core.permit ON DELETE CASCADE,
  party_id  bigint NOT NULL REFERENCES core.party,
  role      text NOT NULL CHECK (role IN ('owner', 'applicant', 'contractor', 'design_professional', 'other')),
  -- The source's own label, e.g. 'MASON CONTRACTOR'. Which trades are already
  -- attached to a permit is what tells us whether a vendor has been chosen.
  role_raw  text NOT NULL,
  trade     text,
  PRIMARY KEY (permit_id, party_id, role_raw)
);

CREATE INDEX permit_party_party_idx ON core.permit_party (party_id);

CREATE TABLE core.business_license (
  license_id      bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  record_id       bigint NOT NULL REFERENCES raw.record,
  source_id       smallint NOT NULL REFERENCES ref.source,
  jurisdiction_id smallint NOT NULL REFERENCES ref.jurisdiction,
  source_license_key text NOT NULL,
  -- account + site identify one business at one location across renewals.
  account_number  text,
  site_number     text,
  license_number  text,
  legal_name      text NOT NULL,
  dba_name        text,
  legal_name_norm text GENERATED ALWAYS AS (core.normalize_name(legal_name)) STORED,
  dba_name_norm   text GENERATED ALWAYS AS (core.normalize_name(dba_name)) STORED,
  address_id      bigint REFERENCES core.address,
  address_raw     text NOT NULL,
  license_type_raw text,
  business_category_code text NOT NULL REFERENCES ref.business_category,
  application_type text NOT NULL CHECK (application_type IN ('new', 'renewal', 'change', 'other')),
  application_type_raw text,
  -- applied_on is itself an early signal; starts_on is the opening date the backtest scores against.
  applied_on      date,
  issued_on       date,
  starts_on       date,
  expires_on      date,
  status_raw      text,
  UNIQUE (source_id, source_license_key)
);

CREATE INDEX license_address_idx ON core.business_license (address_id);
CREATE INDEX license_starts_idx  ON core.business_license (jurisdiction_id, starts_on);
CREATE INDEX license_account_idx ON core.business_license (source_id, account_number, site_number);
CREATE INDEX license_legal_trgm_idx ON core.business_license USING gin (legal_name_norm gin_trgm_ops);
CREATE INDEX license_dba_trgm_idx   ON core.business_license USING gin (dba_name_norm gin_trgm_ops);
