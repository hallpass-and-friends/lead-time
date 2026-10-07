const { LOCAL_DATABASE_URL, NEON_DATABASE_URL } = process.env;

export type DatabaseTargetName = "local" | "neon";

export interface IDatabaseTarget {
  name: DatabaseTargetName;
  connectionString: string;
}

const connectionStrings = {
  local: LOCAL_DATABASE_URL,
  neon: NEON_DATABASE_URL,
} as const satisfies Record<DatabaseTargetName, string | undefined>;

export function getDatabaseTarget(name: DatabaseTargetName): IDatabaseTarget {
  const connectionString = connectionStrings[name];
  if (!connectionString) {
    throw new Error(`${name.toUpperCase()}_DATABASE_URL is not set in .env.`);
  }

  return { name, connectionString };
}

export function getDatabaseTargets(): IDatabaseTarget[] {
  return [getDatabaseTarget("local"), getDatabaseTarget("neon")];
}
