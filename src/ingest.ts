import { parseArgs } from "node:util";
import { getDatabaseTarget } from "./config/database-targets.ts";
import { createPool } from "./db/create-pool.ts";
import { finishIngestRun } from "./raw/finish-ingest-run.ts";
import { startIngestRun } from "./raw/start-ingest-run.ts";
import { upsertRecords, type IUpsertCounts } from "./raw/upsert-records.ts";
import { fetchAllPages } from "./socrata/fetch-all-pages.ts";
import type { IDateWindow } from "./socrata/fetch-page.ts";
import { isSourceCode, sourceRegistry, type ISource, type SourceCode } from "./sources/source-registry.ts";

const ISO_DATE = /^\d{4}-\d{2}-\d{2}$/;

interface IIngestOptions {
  sourceCode: SourceCode;
  window: IDateWindow;
  dryRun: boolean;
}

function readOptions(): IIngestOptions {
  const { positionals, values } = parseArgs({
    allowPositionals: true,
    options: {
      since: { type: "string" },
      until: { type: "string" },
      "dry-run": { type: "boolean", default: false },
    },
  });

  const [sourceCode] = positionals;
  if (!sourceCode || !isSourceCode(sourceCode)) {
    throw new Error(`Unknown source. Expected one of: ${Object.keys(sourceRegistry).join(", ")}`);
  }

  // The dates go into the API query text, so only a strict date shape is accepted.
  const { since, until } = values;
  if (!since || !until || !ISO_DATE.test(since) || !ISO_DATE.test(until)) {
    throw new Error("--since and --until are required, as YYYY-MM-DD.");
  }

  return { sourceCode, window: { since, until }, dryRun: values["dry-run"] };
}

async function dryRun(source: ISource, window: IDateWindow): Promise<void> {
  let rowCount = 0;
  for await (const rows of fetchAllPages(source, window)) {
    rowCount += rows.length;
  }

  console.log({ source: source.code, window, rowCount, stored: false });
}

async function ingest(source: ISource, window: IDateWindow): Promise<void> {
  const pool = createPool(getDatabaseTarget("local"));

  try {
    const run = await startIngestRun(pool, source.code, window);
    const totals: IUpsertCounts = { fetched: 0, inserted: 0, changed: 0, unchanged: 0 };

    try {
      for await (const rows of fetchAllPages(source, window)) {
        const counts = await upsertRecords(pool, run, source.keyField, rows);
        totals.fetched += counts.fetched;
        totals.inserted += counts.inserted;
        totals.changed += counts.changed;
        totals.unchanged += counts.unchanged;
        console.log(`stored ${totals.fetched} rows`);
      }
    } catch (error) {
      // Record the failure on the run before rethrowing, so a failed run is visible in the database.
      await finishIngestRun(pool, run, totals, error);
      throw error;
    }

    await finishIngestRun(pool, run, totals);
    console.log({ source: source.code, window, ingestRunId: run.ingestRunId, ...totals });
  } finally {
    await pool.end();
  }
}

async function main(): Promise<void> {
  const { sourceCode, window, dryRun: isDryRun } = readOptions();
  const source = sourceRegistry[sourceCode];
  if (isDryRun) {
    await dryRun(source, window);
    return;
  }

  await ingest(source, window);
}

await main();
