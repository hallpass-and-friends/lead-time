import { join } from "node:path";
import { readSlugArgument, runSqlFile } from "./db/run-sql-file.ts";

const TRANSFORM_DIR = join("db", "transforms");

const name = readSlugArgument("npm run normalize -- <transform-name>, for example chicago-building-permits.");
await runSqlFile(TRANSFORM_DIR, name);
