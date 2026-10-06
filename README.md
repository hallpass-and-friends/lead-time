# Lead Time

Lead Time uses public records to spot new businesses before they open, and measures how far ahead of the opening the records show them.

A new restaurant leaves a paper trail months before its first customer: a build-out permit, a license application, sometimes a sign permit. Those records are public, but they are messy. A building permit names an address, an owner, and a contractor, and almost never the business that is moving in. The work in this project is linking those records to each other and to the business that eventually opens, then scoring how reliable each early signal is.

## The problem

A permit at an address is a weak signal by itself, because existing businesses file permits for routine work all the time. The signal becomes useful only when records are combined: knowing whether the address has housed this kind of business before, what kind of permit it is, and which other filings sit alongside it. Timing matters too, since some records appear early in a build-out and others only after the vendors have been chosen.

## Approach

The pipeline has four layers, each in its own database schema:

1. **Raw.** Every source record is kept exactly as received, with a new version stored whenever the publisher changes it.
2. **Core.** Permits, licenses, addresses, and the people and companies named on them are normalized into one shape, whatever the source city calls its columns.
3. **Resolve.** Records are linked to each other. Every link carries a score and the evidence behind it, so a match can be explained and different matching methods can be compared.
4. **Lead.** Dated signals at an address are scored into leads as of a given day, then checked against what actually opened.

Two ideas shape the design:

- **Provenance.** Any lead can be traced back through its signals to the original source rows.
- **Honest backtesting.** A scoring run only sees records that were public on its as-of date. Results are reported as precision, recall, and median lead time in days.

## Scope

The first version covers one city and one kind of business: food businesses in Chicago, using the city's building permit and business license datasets. The schema is not tied to Chicago. Adding a city means adding sources and reference rows, not new tables.

## Stack

- PostgreSQL 18 with PostGIS and `pg_trgm`, for address handling and fuzzy name matching inside the database
- TypeScript on Node.js for ingestion
- Docker for the local database, with a hosted copy of the curated data on Neon

## Status

Early. The schema is in place and the environment is set up. Ingestion, matching, and scoring are not built yet.

## Data

Source data is published by the City of Chicago through its open data portal. This project is independent and is not affiliated with or endorsed by the city.
