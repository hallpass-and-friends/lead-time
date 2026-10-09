import { readFile } from "node:fs/promises";
import { join } from "node:path";
import type { QueryResult } from "pg";
import { getDatabaseTarget } from "../config/database-targets.ts";
import { createPool } from "./create-pool.ts";

// The name becomes part of a file path, so only a plain slug is accepted.
const SLUG = /^[a-z0-9-]+$/;

export function readSlugArgument(usage: string): string {
  const [name] = process.argv.slice(2);
  if (!name || !SLUG.test(name)) {
    throw new Error(`Usage: ${usage}`);
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

export async function runSqlFile(directory: string, name: string): Promise<void> {
  const sql = await readFile(join(directory, `${name}.sql`), "utf8");
  const pool = createPool(getDatabaseTarget("local"));
  const client = await pool.connect();
  const startedAt = Date.now();

  try {
    // One transaction for the whole file: it either fully applies or changes nothing.
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
