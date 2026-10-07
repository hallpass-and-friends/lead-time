-- A record can change and later change back (a permit status that is corrected,
-- then restored). The original three-column unique constraint would reject the
-- third version because its hash matches the first. The rule that matters is
-- "one current version per record", which record_current_uq already enforces.

ALTER TABLE raw.record
  DROP CONSTRAINT IF EXISTS record_source_id_source_key_payload_hash_key;

-- Version history for one record is still looked up by key.
CREATE INDEX IF NOT EXISTS record_key_idx ON raw.record (source_id, source_key);
