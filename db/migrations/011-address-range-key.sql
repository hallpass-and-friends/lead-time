-- Put the number range into the premises key.
-- A license at "1000-1002 W RANDOLPH ST" and a permit at "1000 W RANDOLPH ST"
-- produced the same full_key, so whichever arrived second lost its range.
-- base_key keeps only the low number, so both still belong to one building.
-- Safe to re-run: the column is rebuilt from the other columns each time.

ALTER TABLE core.address DROP COLUMN full_key;

ALTER TABLE core.address
  ADD COLUMN full_key text GENERATED ALWAYS AS (
    house_number::text
    || coalesce('-' || house_number_high::text, '')
    || coalesce(' ' || pre_direction, '')
    || ' ' || street_name
    || coalesce(' FL ' || floor, '')
    || coalesce(' #' || unit, '')
  ) STORED;

ALTER TABLE core.address
  ADD CONSTRAINT address_full_key_uq UNIQUE (jurisdiction_id, full_key);
