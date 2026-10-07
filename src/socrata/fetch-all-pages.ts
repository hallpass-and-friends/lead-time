import type { ISource } from "../sources/source-registry.ts";
import { fetchPage, type IDateWindow, type SocrataRow } from "./fetch-page.ts";

const PAGE_SIZE = 5000;

// Yields one page at a time so the caller can store each page before the next
// is fetched, instead of holding a whole window in memory.
export async function* fetchAllPages(source: ISource, window: IDateWindow): AsyncGenerator<SocrataRow[]> {
  for (let offset = 0; ; offset += PAGE_SIZE) {
    const rows = await fetchPage({ source, window, limit: PAGE_SIZE, offset });
    if (rows.length > 0) {
      yield rows;
    }
    if (rows.length < PAGE_SIZE) {
      return;
    }
  }
}
