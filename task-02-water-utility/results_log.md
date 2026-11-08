# Results log (Exercise Pack 3, Water Utility)

Timings are the **median of 3 runs** of `EXPLAIN (ANALYZE, BUFFERS)` (execution time, warm cache), PostgreSQL 18 on a laptop. Full plans are in `plans/`.

| Task | Query | Time before (ms) | Time after (ms) | Plan before | Plan after | Index or table size |
|---|---|---|---|---|---|---|
| 2.2 | Q1 (baseline) | 163.44 | - | Parallel Seq Scan on telemetry | - | - |
| 2.2 | Q2 (baseline) | 159.98 | - | Parallel Seq Scan on telemetry | - | - |
| 2.2 | Q3 (baseline) | 642.07 | - | Parallel Seq Scan on invoice i | - | - |
| 2.2 | Q4 (baseline) | 1167.59 | - | Parallel Seq Scan on invoice | - | - |
| 2.2 | Q5 (baseline) | 70.14 | - | Seq Scan on customer | - | - |
| 2.2 | Q6 (baseline) | 8.89 | - | Seq Scan on water_meter m | - | - |
| 2.3 | Q1 covering index | 163.44 | 0.25 | Parallel Seq Scan on telemetry | Index Only Scan using ix_telemetry_station_ts on telemetry | ix_telemetry_station_ts 124 MB |
| 2.4 | Q2 BRIN | 159.98 | 8.75 | Parallel Seq Scan on telemetry | Bitmap Heap Scan on telemetry | BRIN 24 kB |
| 2.4 | Q2 BRIN only | 159.98 | 7.63 | Parallel Seq Scan on telemetry | Bitmap Heap Scan on telemetry | BRIN 24 kB |
| 2.4 | Q2 B-tree only | 159.98 | 9.69 | Parallel Seq Scan on telemetry | Index Scan using ix_telemetry_ts_btree on telemetry | B-tree 18 MB |
| 2.5 | Q1 partitioned | 163.44 | 0.16 | Parallel Seq Scan on telemetry | Index Only Scan using telemetry_part_2026_08_station_id_ts_pressure_bar_flow_m3h_idx on telemetry_part_2026_08 telemetry_part | partitions scanned: telemetry_part_2026_08 |
| 2.5 | Q2 partitioned | 159.98 | 8.50 | Parallel Seq Scan on telemetry | Index Only Scan using telemetry_part_2026_10_station_id_ts_pressure_bar_flow_m3h_idx on telemetry_part_2026_10 telemetry_part | partitions scanned: telemetry_part_2026_10 |
| 2.6 | Q6 FK index | 8.89 | 0.15 | Seq Scan on water_meter m | Index Scan using ix_water_meter_account on water_meter m | ix_water_meter_account 3104 kB |
| 2.6 | Q3 FK index | 642.07 | 579.53 | Parallel Seq Scan on invoice i | Parallel Seq Scan on invoice i | ix_customer_district 704 kB |
| 2.7 | Q4 partial index | 1167.59 | 378.01 | Parallel Seq Scan on invoice | Index Only Scan using ix_invoice_open on invoice | partial 13 MB vs normal 89 MB |
| 2.8 | Q5 trigram | 70.14 | 15.31 | Seq Scan on customer | Bitmap Heap Scan on customer | GIN trigram 3536 kB |
| 2.9 | October report: correlated vs LAG() | 851.33 | 2500.48 | Parallel Seq Scan on meter_reading r | Index Scan using meter_reading_meter_id_reading_date_key on meter_reading | same rows: rows only in original: 0; only in LAG: 0 |
| 2.9 | extra: correlated vs LAG() on 2 months | 851.33 | 332.93 | Parallel Seq Scan on meter_reading r | Parallel Seq Scan on meter_reading | rows only in original: 0; only in bounded LAG: 0 |
| 2.10 | district 'District 5': base tables vs view | 234.89 | 0.14 | Parallel Seq Scan on customer c | Seq Scan on district_monthly | view 48 kB |

## Extra notes

- 2.5 retention: DELETE 280.1 ms; DETACH 45.0 ms + DROP 18.3 ms (copy 28579 ms; index 3352 ms).
- 2.4 kept index: BRIN only (BRIN 24 kB vs B-tree 18 MB).
- 2.10 steps: Nov readings insert 4581 ms; generate_invoices(Oct) 7884 ms; REFRESH CONCURRENTLY 693 ms; Oct rows in view before=0, after=23|3600701; check=100000|100000.

## Task 2.1: row counts and total size (table + indexes)

| Table | Rows | Total size |
|---|---|---|
| telemetry | 2,628,000 | 151 MB |
| meter_reading | 2,400,017 | 223 MB |
| invoice | 2,300,012 | 309 MB |
