import { Pool } from "pg";
import type { IDatabaseTarget } from "../config/database-targets.ts";

export function createPool(target: IDatabaseTarget): Pool {
  // The ingester works one page at a time, so it never needs many connections.
  return new Pool({ connectionString: target.connectionString, max: 2 });
}
