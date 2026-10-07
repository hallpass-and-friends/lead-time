import type { Pool } from "pg";
import type { IDateWindow } from "../socrata/fetch-page.ts";

export interface IIngestRun {
  ingestRunId: string;
  sourceId: number;
}

const START_RUN_SQL = `
  INSERT INTO raw.ingest_run (source_id, window_start, window_end, params)
  SELECT s.source_id, $2::date, $3::date, $4::jsonb
  FROM ref.source s
  WHERE s.code = $1
  RETURNING ingest_run_id AS "ingestRunId", source_id AS "sourceId"
`;

export async function startIngestRun(pool: Pool, sourceCode: string, window: IDateWindow): Promise<IIngestRun> {
  const params = JSON.stringify({ since: window.since, until: window.until });
  const { rows } = await pool.query<IIngestRun>(START_RUN_SQL, [sourceCode, window.since, window.until, params]);
  const run = rows[0];
  if (!run) {
    throw new Error(`Source "${sourceCode}" is not in ref.source. Has the seed migration been run?`);
  }

  return run;
}
