# Task 3: Star Schema, SCD Type 2 and Analytical Queries

A small retail data warehouse built in PostgreSQL with pgAdmin. It shows how a
star schema works, how to keep history with Slowly Changing Dimensions (SCD
Type 2), and how to check data quality.

## What you build

| Table | Grain (one row per...) | Notes |
|-------|------------------------|-------|
| `dim_date` | day, 2020-2035 | weekend and holiday flags, quarter, "Unknown" row `-1` |
| `dim_store` | store version | `format` is SCD Type 2, `store_code` is the natural key |
| `dim_product` | product version | `category` is SCD Type 2 |
| `dim_customer` | customer version | `region` and `loyalty_tier` are Type 2, `phone` is Type 1, keys `-1` and `0` |
| `fact_sales` | receipt line | only keys and measures, `receipt_no` is a degenerate dimension, `UNIQUE (receipt_no, line_no)` |
| `fact_returns` | returned line | same dimensions as `fact_sales` (Task 3) |

## Requirements

- PostgreSQL 14 or newer (tested on 18)
- pgAdmin, or the `psql` command line tool

## How to run

1. Create an empty database, for example `deaa_l4`.
2. Open **Tools > Query Tool** in pgAdmin and run the files in `sql/` in order.
   Run each file with **F5** and read the **Messages** tab. If a file fails,
   fix it before you continue, because later files depend on earlier ones.
3. For `10_query_plan.sql` and `14_task4_performance.sql` use
   **Explain > Analyze (F7)** and compare the execution time.

With `psql` you can run everything in one go. Enter your own password when asked:

```bash
cat sql/*.sql | psql -U postgres -h localhost -d deaa_l4 -v ON_ERROR_STOP=1
```

> `01_schema.sql` drops and recreates the `dw` schema. Only run it when you
> want to start from scratch.

## Files

| File | What it does |
|------|--------------|
| `01_schema.sql` | creates the `dw` schema |
| `02_dim_date.sql` | date dimension with Uzbek public holidays |
| `03_dim_store.sql` | store dimension |
| `04_dim_product.sql` | product dimension |
| `05_dim_customer.sql` | customer dimension and "one current row" indexes |
| `06_fact_sales.sql` | sales fact table and a helper function for the right surrogate key |
| `07_scd2_load.sql` | manual SCD Type 2 load (a customer moves to a new region) |
| `08_analytics.sql` | analytical queries |
| `09_data_quality.sql` | data quality tests (each must return 0 rows) |
| `10_query_plan.sql` | query plan before and after indexing |
| `11_task1_product_scd2.sql` | Task 1: product category change |
| `12_task2_store_scd2.sql` | Task 2: store format change |
| `13_task3_returns.sql` | Task 3: returns fact table |
| `14_task4_performance.sql` | Task 4: 100,000 rows and index test |

## Expected results

- **SCD load:** customer `C-10077` has two rows. Key 1 is Samarkand (closed on 2026-07-01), key 3 is Tashkent city (current). Both have the new phone number.
- **Sales by region (as of sale time):** Samarkand 38,000, Tashkent city 18,000, N/A 12,000 (cash sales).
- **Sales by current region:** Tashkent city 56,000, N/A 12,000.
- **Natural key join mistake:** wrong sum 124,000, correct sum 68,000.
- **Data quality tests:** all four return 0 rows.

## The four tasks

1. **Product SCD Type 2.** `P-0003` moves from `Beverages` to `Functional drinks` on 2026-09-01. Q1 sales (8,000) still show under `Beverages`, and the September sale (18,000) shows under the new category.
2. **Store SCD Type 2.** `S-041` becomes a `supermarket` on 2026-05-15. Sales before the change (12,000) stay under `minimarket`, sales after (20,000) go under `supermarket`.
3. **Returns fact.** `fact_returns` is added with the same dimensions. Net sales minus returns: Tashkent city 64,000, Samarkand 23,000. The two facts are summed separately before they are joined, to avoid duplicated rows.
4. **Performance.** After adding 100,000 random rows, a query that selects one day takes about 4.6 ms without an index and about 0.65 ms with an index. A query that groups the whole table (sales by store region) stays at about 38 ms either way, because it reads every row. Indexes help most when a query picks a small part of the table.

## Key ideas

- **Surrogate keys** let a fact row point to the exact version of a dimension row that was valid at the time of the sale.
- **SCD Type 2** keeps history: close the old row, add a new row. **Type 1** simply overwrites the value.
- **Unknown members** (`-1`, and `0` for "no loyalty card") keep fact rows valid when a value is missing.
- **Joining on the natural key** instead of the surrogate key repeats rows and gives wrong totals.
- **Money** is stored as `NUMERIC`, never `FLOAT`.
