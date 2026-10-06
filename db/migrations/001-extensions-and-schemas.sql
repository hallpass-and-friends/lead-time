-- Lead Time: extensions and schema namespaces.
-- Run order is the file number. Every file is safe to run on an empty database.

CREATE EXTENSION IF NOT EXISTS pg_trgm;
CREATE EXTENSION IF NOT EXISTS fuzzystrmatch;
CREATE EXTENSION IF NOT EXISTS postgis;

-- One schema per pipeline layer, so a table's layer is visible in every query
-- and the raw layer can be left out of the hosted database without renaming anything.
CREATE SCHEMA IF NOT EXISTS ref;      -- lookups: jurisdictions, sources, categories
CREATE SCHEMA IF NOT EXISTS raw;      -- source records exactly as received
CREATE SCHEMA IF NOT EXISTS core;     -- normalized addresses, parties, permits, licenses
CREATE SCHEMA IF NOT EXISTS resolve;  -- links between records, with scores and evidence
CREATE SCHEMA IF NOT EXISTS lead;     -- signals, scored leads, and backtest outcomes
