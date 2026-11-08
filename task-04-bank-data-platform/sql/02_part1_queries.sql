SET search_path TO bank;

\echo '--- 1.3a transfer legs net to zero (test: must return 0 rows)'
SELECT transaction_id, SUM(amount_uzs) FROM fact_transaction
WHERE transaction_id = 'T-2' GROUP BY transaction_id HAVING SUM(amount_uzs) <> 0;

\echo '--- 1.3b net inflow by region, 2026-03-02..03-03'
SELECT b.region, SUM(t.amount_uzs) AS net_inflow
FROM fact_transaction t JOIN dim_branch b ON b.branch_key = t.branch_key
WHERE t.date_key BETWEEN 20260302 AND 20260303
GROUP BY b.region ORDER BY b.region;

\echo '--- 1.3c bank-wide net inflow (transfer must cancel out)'
SELECT SUM(amount_uzs) AS bank_net_inflow FROM fact_transaction WHERE date_key BETWEEN 20260302 AND 20260303;

\echo '--- 1.3d total deposits by region on 03-01 and 03-03, and the reconciliation'
SELECT b.region,
       SUM(f.closing_balance_uzs) FILTER (WHERE f.date_key = 20260301) AS deposits_mar01,
       SUM(f.closing_balance_uzs) FILTER (WHERE f.date_key = 20260303) AS deposits_mar03,
       SUM(f.closing_balance_uzs) FILTER (WHERE f.date_key = 20260303)
     - SUM(f.closing_balance_uzs) FILTER (WHERE f.date_key = 20260301) AS change_in_deposits
FROM fact_daily_balance f JOIN dim_branch b ON b.branch_key = f.branch_key
GROUP BY b.region ORDER BY b.region;

\echo '--- 1.4 average monthly balance per customer (CORRECT: sum accounts per day, then AVG over days)'
WITH customer_day AS (
    SELECT customer_key, date_key, SUM(closing_balance_uzs) AS balance
    FROM fact_daily_balance GROUP BY customer_key, date_key
)
SELECT c.client_no, d.year, d.month_num, ROUND(AVG(cd.balance), 2) AS avg_monthly_balance
FROM customer_day cd
JOIN dim_date d     ON d.date_key = cd.date_key
JOIN dim_customer c ON c.customer_key = cd.customer_key
GROUP BY c.client_no, d.year, d.month_num ORDER BY c.client_no;

\echo '--- 1.4 per branch: average of the daily branch total'
WITH branch_day AS (
    SELECT branch_key, date_key, SUM(closing_balance_uzs) AS balance
    FROM fact_daily_balance GROUP BY branch_key, date_key
)
SELECT br.branch_name, d.year, d.month_num, ROUND(AVG(bd.balance), 2) AS avg_monthly_balance
FROM branch_day bd
JOIN dim_date d    ON d.date_key = bd.date_key
JOIN dim_branch br ON br.branch_key = bd.branch_key
GROUP BY br.branch_name, d.year, d.month_num ORDER BY br.branch_name;

\echo '--- 1.4 WRONG: SUM over days (31 days counted as 31x the balance)'
SELECT c.client_no, SUM(f.closing_balance_uzs) AS wrong_sum_over_days
FROM fact_daily_balance f JOIN dim_customer c ON c.customer_key = f.customer_key
GROUP BY c.client_no ORDER BY c.client_no;

\echo '--- 1.5 change-only storage: time-weighted average must equal the daily AVG'
WITH changes AS (
    SELECT account_key, date_key, closing_balance_uzs,
           LAG(closing_balance_uzs) OVER (PARTITION BY account_key ORDER BY date_key) AS prev_bal
    FROM fact_daily_balance
), periods AS (
    SELECT account_key, date_key AS from_key, closing_balance_uzs AS balance,
           LEAD(date_key) OVER (PARTITION BY account_key ORDER BY date_key) AS next_from_key
    FROM changes WHERE prev_bal IS DISTINCT FROM closing_balance_uzs
), weighted AS (
    SELECT p.account_key, p.balance,
           (COALESCE(TO_DATE(p.next_from_key::TEXT,'YYYYMMDD'), DATE '2026-04-01')
            - TO_DATE(p.from_key::TEXT,'YYYYMMDD')) AS days
    FROM periods p
)
SELECT a.customer_key, ROUND(SUM(w.balance * w.days) / 31.0, 2) AS time_weighted_avg
FROM weighted w JOIN dim_account a ON a.account_key = w.account_key
GROUP BY a.customer_key ORDER BY a.customer_key;

\echo '--- row counts of change-only vs daily snapshot (sample)'
SELECT (SELECT COUNT(*) FROM fact_daily_balance) AS daily_rows,
       (SELECT COUNT(*) FROM (
           SELECT account_key, closing_balance_uzs,
                  LAG(closing_balance_uzs) OVER (PARTITION BY account_key ORDER BY date_key) AS prev_bal
           FROM fact_daily_balance) x WHERE prev_bal IS DISTINCT FROM closing_balance_uzs) AS change_rows;
