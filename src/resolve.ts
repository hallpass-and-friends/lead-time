import { join } from "node:path";
import { readSlugArgument, runSqlFile } from "./db/run-sql-file.ts";

const RESOLVE_DIR = join("db", "resolve");

const name = readSlugArgument("npm run resolve -- <jurisdiction>, for example chicago.");
await runSqlFile(RESOLVE_DIR, name);
