# Task 2: Database Implementation and Optimization (Water Utility)

A PostgreSQL database for a fictional regional water supply company, built in
two parts. Everything is invented for teaching.

- **Part 1 - Implementation.** Schema with constraints, a trigger that keeps
  meter readings increasing, a monthly consumption view, tariffs with validity
  periods (exclusion constraint), billing procedure, payments, incidents,
  water quality alerts and row-level security for district operators.
- **Part 2 - Optimization.** About 2.6 million sensor records, 2.4 million meter
  readings and 2.3 million invoices. Six slow queries are measured with
  `EXPLAIN (ANALYZE, BUFFERS)`, then fixed with indexes, partitioning, a partial
  index, a trigram index, a query rewrite and a materialized view.

## Files

| File | What it is |
|------|------------|
| `lab3.sql` | Every statement that was run, in order (the file to submit) |
| `results_log.md` | Results table: time before and after, plan before and after, index size |
| `plans/` | Full `EXPLAIN (ANALYZE, BUFFERS)` output of each measured query |
| `sql/` | The scripts for Part 1 and for the data generation |
| `scripts/` | Python and shell helpers that run and measure Part 2 |

## How to run

Use PostgreSQL 15 or newer (tested on 18). Passwords are never stored in these
files; you pass them in yourself.

```bash
cd scripts
export PGPASSWORD=your_postgres_password
export OPPW=password_for_the_district_operator_role
./rebuild.sh        # creates the database "suvta", loads the data, runs all measurements
python make_log.py  # builds results_log.md from results.json
```

You can also run `lab3.sql` by hand in pgAdmin or `psql`. Task 1.10 needs a
variable for the role password: `psql -v op_pw=your_password -f ...`.
Generating the data takes a few minutes.

## Main results

| Task | Change | Before | After |
|------|--------|--------|-------|
| 2.3 | Covering index for one station and one day | about 160 ms | about 0.25 ms |
| 2.4 | BRIN index on the time column (24 kB; a B-tree needs 18 MB) | about 160 ms | about 8 ms |
| 2.6 | Index on the foreign key `water_meter(account_no)` | about 9 ms | about 0.15 ms |
| 2.7 | Partial index for unpaid invoices (13 MB; a normal one needs 89 MB) | about 1,170 ms | about 380 ms |
| 2.8 | Trigram index for address search | about 70 ms | about 15 ms |
| 2.10 | Materialized view for management reports | about 235 ms | about 0.14 ms |

Timings are the median of three runs on a laptop and change a little from run
to run. The ratios are stable.

## Things that did not go as expected

- **2.9:** the `LAG()` rewrite returns exactly the same rows but is *slower*
  than the correlated subquery (about 2,500 ms against 850 ms), because the
  window is computed over the whole table. Limiting the window to two months
  makes it faster (about 330 ms) and still returns the same rows.
- **2.6:** the foreign key index barely helps the district report (Q3), because
  that query reads most of the invoice table anyway.
- **2.3:** a plain `(station_id, ts)` index did not give an ordered index scan,
  so the index includes `pressure_bar` and `flow_m3h`.
- **2.4:** PostgreSQL 18 can also use the 2.3 index for Q2, so that index was
  hidden (inside a rolled-back transaction) during the BRIN and B-tree comparison.
- **2.5:** dropping a monthly partition (about 63 ms) is much cheaper than a
  `DELETE` of the same month (about 280 ms).
