export interface ISource {
  code: string;
  domain: string;
  datasetId: string;
  keyField: string;
  dateField: string;
}

// Codes match ref.source.code in the database, which is how a run finds its source row.
export const sourceRegistry = {
  "chicago-building-permits": {
    code: "chicago-building-permits",
    domain: "data.cityofchicago.org",
    datasetId: "ydr8-5enu",
    keyField: "id",
    dateField: "issue_date",
  },
  "chicago-business-licenses": {
    code: "chicago-business-licenses",
    domain: "data.cityofchicago.org",
    datasetId: "r5kz-chrr",
    // Not "id": that is license number plus start date, and repeats when one
    // license has two actions with the same start date.
    keyField: "license_id",
    dateField: "license_start_date",
  },
} as const satisfies Record<string, ISource>;

export type SourceCode = keyof typeof sourceRegistry;

export function isSourceCode(value: string): value is SourceCode {
  return Object.hasOwn(sourceRegistry, value);
}
