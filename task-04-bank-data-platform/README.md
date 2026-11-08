# Task 4: Bank Data Platform Case Study (Zarafshon Bank)

A written case study with a working PostgreSQL prototype. The bank is
fictional and every figure is invented for teaching. The task is to design a
data platform that answers six management questions: deposit inflow, average
balances, card declines, loan speed, customer history, and data localisation.

## What is inside

| Part | Topic | What I built |
|------|-------|--------------|
| 1 | Dimensional model | `fact_transaction` (one posting leg) and `fact_daily_balance` (one account per day), transfers as two signed rows, average monthly balance |
| 2 | Customer history | SCD types per attribute, Type 2 history for one customer, late-arriving changes with fact re-keying |
| 3 | Loan lifecycle | Accumulating snapshot `fact_loan_application`, nightly MERGE load, median days from approval to disbursement |
| 4 | Data vault | Hubs, links and satellites for four customer sources, address conflict, audit query |
| 5 | Pipeline and compliance | Incremental load with corrections, five data-quality tests, streaming design, personal data, cost |

## Folders

- `report/` the final PDF (8 pages of answers plus the SQL appendix) and the
  text of each part in Markdown.
- `sql/` runnable scripts, numbered in the order you should run them.

## How to run

1. Create an empty database in PostgreSQL 15 or newer (tested on 18).
2. Run the scripts in `sql/` in order, for example in pgAdmin Query Tool or with `psql`.
   Enter your own password when asked:

```bash
cat sql/0*.sql | psql -U postgres -h localhost -d your_database -v ON_ERROR_STOP=1
```

Part 1 creates the `bank` schema (and drops it if it exists). Part 4 creates a
separate `vault` schema. PostgreSQL 15 or newer is needed for `MERGE` in Part 3.

## Some results you can check

- Transfer from Tashkent to Samarkand: net inflow Tashkent -50, Samarkand +100, whole bank +50.
- Average monthly balance, March 2026: 954.84, 593.55 and 1,883.87 (the sum over days would be wrong).
- Customer 4471 has 3 rows in `dim_customer`; exactly 1 is valid on 2026-04-05.
- Nightly loan load: the second night changes only 2 rows; running it again changes 0.
- Median days from approval to disbursement in Q3 2026: Chilonzor 10, Registan 11.
- Incremental load test: `inserted=2 corrected=1 unchanged=1 duplicates_in_file=1`.

## Note on the law check

Part 5.4 refers to Uzbekistan's personal data law. The 2026 amendments were
checked in news and law-firm articles only, not in the official text, so
confirm the wording on lex.uz before relying on it.
