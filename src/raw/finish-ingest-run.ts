import type { Pool } from "pg";
import type { IIngestRun } from "./start-ingest-run.ts";
import type { IUpsertCounts } from "./upsert-records.ts";

const FINISH_RUN_SQL = `
  UPDATE raw.ingest_run
  SET finished_at = now(),
      status = $2,
      rows_fetched = $3,
      rows_new = $4,
      rows_changed = $5,
      error_message = $6
  WHERE ingest_run_id = $1
`;

export async function finishIngestRun(pool: Pool, run: IIngestRun, totals: IUpsertCounts, error?: unknown): Promise<void> {
  const status = error === undefined ? "succeeded" : "failed";
  const message = error === undefined ? null : error instanceof Error ? error.message : String(error);

  await pool.query(FINISH_RUN_SQL, [run.ingestRunId, status, totals.fetched, totals.inserted, totals.changed, message]);
}
