import { Client } from "pg";
import { getDatabaseTargets, type IDatabaseTarget } from "./config/database-targets.ts";

interface IConnectionReport {
  name: string;
  serverVersion: string;
  postgisVersion: string | null;
  schemaObjects: number;
}

const REPORT_SQL = `
  SELECT
    current_setting('server_version') AS "serverVersion",
    (SELECT extversion FROM pg_extension WHERE extname = 'postgis') AS "postgisVersion",
    (SELECT count(*)::int FROM information_schema.tables
      WHERE table_schema IN ('ref', 'raw', 'core', 'resolve', 'lead')) AS "schemaObjects"
`;

async function checkTarget(target: IDatabaseTarget): Promise<IConnectionReport> {
  const client = new Client({ connectionString: target.connectionString });
  await client.connect();

  try {
    const { rows } = await client.query<Omit<IConnectionReport, "name">>(REPORT_SQL);
    const row = rows[0];
    if (!row) {
      throw new Error(`No report row returned from ${target.name}.`);
    }

    return { name: target.name, ...row };
  } finally {
    // Always release the connection, or the script hangs on a failed query.
    await client.end();
  }
}

async function main(): Promise<void> {
  const reports = await Promise.all(getDatabaseTargets().map(checkTarget));
  console.table(reports);
}

await main();
