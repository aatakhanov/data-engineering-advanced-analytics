SET search_path TO bank;

\echo '=== 5.1 load F1, then F2, then F2 again'
SELECT load_core_file('F1', '2026-11-02 02:10');
SELECT load_core_file('F2', '2026-11-03 02:15');
SELECT load_core_file('F2', '2026-11-03 03:00');

\echo '=== 5.1 correction applied, old value kept in the audit table'
SELECT f.transaction_id, f.amount_uzs AS current_amount, a.old_amount_uzs, a.changed_by_file
FROM fact_transaction f JOIN fact_transaction_audit a USING (txn_leg_id);

\echo '=== 5.1 no duplicates in the fact (must be 0 rows)'
SELECT transaction_id, leg_no, COUNT(*) FROM fact_transaction GROUP BY 1,2 HAVING COUNT(*) > 1;

\echo '=== 5.1 yesterday''s aggregate for Question 1 (2026-11-01 reflects the correction: 450, not 500)'
SELECT date_key, region, segment, net_inflow_uzs FROM agg_daily_inflow WHERE date_key >= 20261101 ORDER BY 1,2,3;

-- ====================== 5.3 data quality tests ======================
\echo '=== T1 grain: one row per (transaction_id, leg_no) - must be 0 rows'
SELECT transaction_id, leg_no, COUNT(*) FROM fact_transaction GROUP BY 1,2 HAVING COUNT(*) > 1;

\echo '=== T2 referential integrity: facts whose customer key is missing in the dimension - must be 0 rows'
SELECT f.txn_leg_id FROM fact_transaction f LEFT JOIN dim_customer c ON c.customer_key = f.customer_key
WHERE c.customer_key IS NULL;

\echo '=== T3 no overlapping Type 2 rows - must be 0 rows'
SELECT a.client_no FROM dim_customer a JOIN dim_customer b
  ON a.client_no = b.client_no AND a.customer_key <> b.customer_key
 AND a.valid_from < b.valid_to AND b.valid_from < a.valid_to;

\echo '=== T4 reconciliation: rows and total of each loaded file vs the control file - must be 0 rows'
SELECT c.file_id, c.row_count, d.rows_loaded, c.total_amount, d.amount_loaded
FROM src_control c
JOIN (SELECT file_id, COUNT(*) AS rows_loaded, SUM(amount_uzs) AS amount_loaded
        FROM (SELECT DISTINCT ON (file_id, transaction_id, leg_no) * FROM stg_core_txn
               ORDER BY file_id, transaction_id, leg_no, row_seq DESC) x GROUP BY file_id) d USING (file_id)
WHERE c.row_count <> d.rows_loaded OR c.total_amount <> d.amount_loaded;

\echo '=== T5 freshness: last successful load older than 26 hours at 08:00 - must be 0 rows'
SELECT MAX(loaded_at) AS last_load, TIMESTAMP '2026-11-03 08:00' - MAX(loaded_at) AS age
FROM load_log HAVING TIMESTAMP '2026-11-03 08:00' - MAX(loaded_at) > INTERVAL '26 hours';

\echo '=== T5 same test, 2 days later (stale -> must fail, returns 1 row)'
SELECT MAX(loaded_at) AS last_load, TIMESTAMP '2026-11-05 08:00' - MAX(loaded_at) AS age
FROM load_log HAVING TIMESTAMP '2026-11-05 08:00' - MAX(loaded_at) > INTERVAL '26 hours';

-- ====================== 5.5 volume ======================
\echo '=== 5.5 volume'
SELECT 9000000::NUMERIC * 200 / 1e9 AS gb_per_day_raw,
       9000000::NUMERIC * 200 * 365 / 1e9 AS gb_per_year_raw,
       9000000::NUMERIC * 200 * 365 / 5 / 1e9 AS gb_per_year_parquet;
