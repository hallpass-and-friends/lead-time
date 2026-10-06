-- Raw layer: every source record exactly as received.
-- Kept in full on the local database; the hosted database holds only the rows
-- that curated records point to.

CREATE TABLE raw.ingest_run (
  ingest_run_id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  source_id     smallint NOT NULL REFERENCES ref.source,
  started_at    timestamptz NOT NULL DEFAULT now(),
  finished_at   timestamptz,
  status        text NOT NULL DEFAULT 'running' CHECK (status IN ('running', 'succeeded', 'failed')),
  window_start  date,
  window_end    date,
  rows_fetched  integer,
  rows_new      integer,
  rows_changed  integer,
  params        jsonb NOT NULL DEFAULT '{}',
  error_message text,
  CHECK (finished_at IS NULL OR finished_at >= started_at)
);

CREATE INDEX ingest_run_source_idx ON raw.ingest_run (source_id, started_at DESC);

CREATE TABLE raw.record (
  record_id         bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  source_id         smallint NOT NULL REFERENCES ref.source,
  -- The publisher's own row identifier.
  source_key        text NOT NULL,
  payload           jsonb NOT NULL,
  -- Used only to notice that a record changed, so md5 is enough. jsonb text output
  -- is canonical, so key order and spacing in the source do not create false changes.
  payload_hash      text GENERATED ALWAYS AS (md5(payload::text)) STORED,
  first_seen_run_id bigint NOT NULL REFERENCES raw.ingest_run,
  last_seen_run_id  bigint NOT NULL REFERENCES raw.ingest_run,
  first_seen_at     timestamptz NOT NULL DEFAULT now(),
  -- Publishers overwrite rows in place (a permit's status changes, a license renews).
  -- A changed payload is stored as a new version so a backtest can ask what was
  -- knowable on a given day instead of reading today's value into the past.
  superseded_at     timestamptz,
  UNIQUE (source_id, source_key, payload_hash)
);

CREATE UNIQUE INDEX record_current_uq ON raw.record (source_id, source_key) WHERE superseded_at IS NULL;
