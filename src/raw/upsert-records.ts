import type { Pool } from "pg";
import type { SocrataRow } from "../socrata/fetch-page.ts";
import type { IIngestRun } from "./start-ingest-run.ts";

export interface IUpsertCounts {
  fetched: number;
  inserted: number;
  changed: number;
  unchanged: number;
}

// The page arrives as one JSON parameter and is unpacked in the database, so a
// page of any size is a single round trip instead of one insert per row.
const STAGE_SQL = `
  INSERT INTO incoming (source_key, payload, payload_hash)
  SELECT elem ->> $2, elem, md5(elem::text)
  FROM jsonb_array_elements($1::jsonb) AS elem
`;

// Every record touched or inserted in a run carries that run's id, so a match
// here means the same key has already appeared earlier in this run.
const SEEN_THIS_RUN_SQL = `
  SELECT count(*)::int AS "duplicates"
  FROM raw.record r
  JOIN incoming i ON i.source_key = r.source_key
  WHERE r.source_id = $1
    AND r.last_seen_run_id = $2
`;

const TOUCH_UNCHANGED_SQL = `
  UPDATE raw.record r
  SET last_seen_run_id = $2
  FROM incoming i
  WHERE r.source_id = $1
    AND r.source_key = i.source_key
    AND r.superseded_at IS NULL
    AND r.payload_hash = i.payload_hash
`;

const SUPERSEDE_CHANGED_SQL = `
  UPDATE raw.record r
  SET superseded_at = now()
  FROM incoming i
  WHERE r.source_id = $1
    AND r.source_key = i.source_key
    AND r.superseded_at IS NULL
    AND r.payload_hash <> i.payload_hash
`;

// Runs after the supersede step, so "no current version" covers both brand-new
// records and records whose old version was just retired.
const INSERT_MISSING_SQL = `
  INSERT INTO raw.record (source_id, source_key, payload, first_seen_run_id, last_seen_run_id)
  SELECT $1, i.source_key, i.payload, $2, $2
  FROM incoming i
  WHERE NOT EXISTS (
    SELECT 1
    FROM raw.record r
    WHERE r.source_id = $1
      AND r.source_key = i.source_key
      AND r.superseded_at IS NULL
  )
`;

export async function upsertRecords(pool: Pool, run: IIngestRun, keyField: string, rows: SocrataRow[]): Promise<IUpsertCounts> {
  const client = await pool.connect();

  try {
    // One transaction per page: a page is either fully stored or not at all.
    await client.query("BEGIN");
    await client.query("CREATE TEMP TABLE incoming (source_key text PRIMARY KEY, payload jsonb NOT NULL, payload_hash text NOT NULL) ON COMMIT DROP");
    await client.query(STAGE_SQL, [JSON.stringify(rows), keyField]);

    const ids = [run.sourceId, run.ingestRunId];

    // Without this check a repeated key would look like a changed record and
    // silently retire the earlier row.
    const seen = await client.query<{ duplicates: number }>(SEEN_THIS_RUN_SQL, ids);
    const duplicates = seen.rows[0]?.duplicates ?? 0;
    if (duplicates > 0) {
      throw new Error(`${duplicates} key(s) in this page were already stored earlier in run ${run.ingestRunId}. The key field "${keyField}" is probably not unique for this source.`);
    }

    const unchanged = await client.query(TOUCH_UNCHANGED_SQL, ids);
    const changed = await client.query(SUPERSEDE_CHANGED_SQL, [run.sourceId]);
    const added = await client.query(INSERT_MISSING_SQL, ids);
    await client.query("COMMIT");

    const changedCount = changed.rowCount ?? 0;
    return {
      fetched: rows.length,
      inserted: (added.rowCount ?? 0) - changedCount,
      changed: changedCount,
      unchanged: unchanged.rowCount ?? 0,
    };
  } catch (error) {
    await client.query("ROLLBACK");
    throw error;
  } finally {
    client.release();
  }
}
