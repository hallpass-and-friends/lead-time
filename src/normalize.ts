import { readFile } from "node:fs/promises";
import { join } from "node:path";
import type { QueryResult } from "pg";
import { getDatabaseTarget } from "./config/database-targets.ts";
import { createPool } from "./db/create-pool.ts";

const TRANSFORM_DIR = join("db", "transforms");
// The name becomes part of a file path, so only a plain slug is accepted.
const TRANSFORM_NAME = /^[a-z0-9-]+$/;

function readTransformName(): string {
  const [name] = process.argv.slice(2);
  if (!name || !TRANSFORM_NAME.test(name)) {
    throw new Error("Usage: npm run normalize -- <transform-name>, for example chicago-building-permits.");
  }

  return name;
}

function printReports(results: QueryResult[]): void {
  for (const result of results) {
    if (result.command !== "SELECT" || result.rows.length === 0) {
      continue;
    }

    // By convention each report query names itself in its first column.
    const { report, ...first } = result.rows[0];
    console.log(`\n${report ?? "result"}`);
    console.table(result.rows.length === 1 ? [first] : result.rows.map(({ report: _ignored, ...row }) => row));
  }
}

async function main(): Promise<void> {
  const name = readTransformName();
  const sql = await readFile(join(TRANSFORM_DIR, `${name}.sql`), "utf8");
  const pool = createPool(getDatabaseTarget("local"));
  const client = await pool.connect();
  const startedAt = Date.now();

  try {
    // One transaction for the whole file: a transform either fully applies or leaves core untouched.
    await client.query("BEGIN");
    // A file with several statements and no parameters comes back as one result per statement.
    const results = (await client.query(sql)) as unknown as QueryResult[];
    await client.query("COMMIT");

    printReports(Array.isArray(results) ? results : [results]);
    console.log(`\n${name} finished in ${((Date.now() - startedAt) / 1000).toFixed(1)}s`);
  } catch (error) {
    await client.query("ROLLBACK");
    throw error;
  } finally {
    client.release();
    await pool.end();
  }
}

await main();
