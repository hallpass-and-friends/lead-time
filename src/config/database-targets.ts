const { LOCAL_DATABASE_URL, NEON_DATABASE_URL } = process.env;

export interface IDatabaseTarget {
  name: "local" | "neon";
  connectionString: string;
}

export function getDatabaseTargets(): IDatabaseTarget[] {
  if (!LOCAL_DATABASE_URL) {
    throw new Error("LOCAL_DATABASE_URL is not set in .env.");
  }
  if (!NEON_DATABASE_URL) {
    throw new Error("NEON_DATABASE_URL is not set in .env.");
  }

  return [
    { name: "local", connectionString: LOCAL_DATABASE_URL },
    { name: "neon", connectionString: NEON_DATABASE_URL },
  ];
}
