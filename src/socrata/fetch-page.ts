import type { ISource } from "../sources/source-registry.ts";

export interface IDateWindow {
  since: string;
  // Exclusive, so consecutive windows never overlap or leave a gap.
  until: string;
}

export interface IPageRequest {
  source: ISource;
  window: IDateWindow;
  limit: number;
  offset: number;
}

export type SocrataRow = Record<string, unknown>;

export async function fetchPage({ source, window, limit, offset }: IPageRequest): Promise<SocrataRow[]> {
  const { dateField } = source;
  const params = new URLSearchParams({
    $where: `${dateField} >= '${window.since}T00:00:00' AND ${dateField} < '${window.until}T00:00:00'`,
    // Paging is only reliable with a stable order; :id is Socrata's internal row id.
    $order: ":id",
    $limit: String(limit),
    $offset: String(offset),
  });

  const url = `https://${source.domain}/resource/${source.datasetId}.json?${params}`;
  const response = await fetch(url, { headers: { Accept: "application/json" } });
  if (!response.ok) {
    throw new Error(`Socrata request failed (${response.status}) for ${source.code}: ${await response.text()}`);
  }

  return (await response.json()) as SocrataRow[];
}
