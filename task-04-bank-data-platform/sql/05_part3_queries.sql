SET search_path TO bank;

\echo '=== 3.2 night 1 (run at 2026-09-15 01:00): rows inserted/updated'
SELECT load_loan_snapshot('2026-09-15 01:00') AS rows_touched;
SELECT COUNT(*) AS rows_in_fact FROM fact_loan_application;

\echo '=== 3.2 night 2 (run at 2026-10-06 01:00): only applications with new events'
SELECT load_loan_snapshot('2026-10-06 01:00') AS rows_touched;
SELECT application_no FROM fact_loan_application WHERE last_event_ts >= '2026-09-15 01:00' ORDER BY 1;

\echo '=== 3.2 re-running the same night changes nothing (idempotent)'
SELECT load_loan_snapshot('2026-10-06 01:00') AS rows_touched;

\echo '=== 3.1 one row per application'
SELECT f.application_no, p.product_code, b.branch_code, s.stage_name AS current_stage,
       f.submitted_date_key, f.decision_date_key, f.disbursed_date_key, f.days_total_to_disbursement
FROM fact_loan_application f
JOIN dim_loan_product p ON p.loan_product_key = f.loan_product_key
JOIN dim_branch b       ON b.branch_key = f.branch_key
JOIN dim_loan_stage s   ON s.stage_key = f.current_stage_key
ORDER BY f.submitted_date_key;

\echo '=== Q4: where do applications stall? average days per step, by product'
SELECT p.product_code,
       ROUND(AVG(days_submit_to_docs),1)     AS submit_to_docs,
       ROUND(AVG(days_docs_to_scored),1)     AS docs_to_scored,
       ROUND(AVG(days_scored_to_decision),1) AS scored_to_decision,
       ROUND(AVG(days_decision_to_signed),1) AS decision_to_signed,
       ROUND(AVG(days_signed_to_disbursed),1) AS signed_to_disbursed
FROM fact_loan_application f JOIN dim_loan_product p USING (loan_product_key)
GROUP BY p.product_code ORDER BY p.product_code;

\echo '=== open applications and how long they have been waiting (age computed at query time, as of 2026-10-06)'
SELECT f.application_no, s.stage_name, DATE '2026-10-06' - TO_DATE(f.last_event_ts::DATE::TEXT,'YYYY-MM-DD') AS days_in_stage
FROM fact_loan_application f JOIN dim_loan_stage s ON s.stage_key = f.current_stage_key
WHERE NOT s.is_terminal ORDER BY days_in_stage DESC;

\echo '=== 3.3 stage counts at month end, rebuilt from the accumulating snapshot (clumsy)'
WITH month_ends AS (SELECT date_key AS me FROM dim_date WHERE year = 2026 AND month_num IN (7,8,9) AND is_month_end),
staged AS (
    SELECT m.me AS month_end,
           CASE WHEN f.submitted_date_key > m.me THEN NULL
                WHEN f.withdrawn_date_key  <= m.me THEN 'withdrawn'
                WHEN f.disbursed_date_key  <= m.me THEN 'disbursed'
                WHEN f.signed_date_key     <= m.me THEN 'signed'
                WHEN f.decision_date_key   <= m.me THEN (CASE WHEN s.stage_name = 'rejected' THEN 'rejected' ELSE 'approved' END)
                WHEN f.scored_date_key     <= m.me THEN 'scored'
                WHEN f.docs_verified_date_key <= m.me THEN 'docs_verified'
                ELSE 'submitted' END AS stage_at_month_end
    FROM fact_loan_application f
    JOIN dim_loan_stage s ON s.stage_key = f.current_stage_key
    CROSS JOIN month_ends m
)
SELECT month_end, stage_at_month_end, COUNT(*) AS applications
FROM staged WHERE stage_at_month_end IS NOT NULL
GROUP BY month_end, stage_at_month_end ORDER BY month_end, stage_at_month_end;

\echo '=== 3.4 median days approval -> disbursement by branch, disbursed in Q3 2026'
SELECT b.branch_name,
       COUNT(*) AS loans,
       PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY f.days_approval_to_disbursement) AS median_days
FROM fact_loan_application f
JOIN dim_branch b ON b.branch_key = f.branch_key
JOIN dim_date d   ON d.date_key = f.disbursed_date_key
WHERE d.year = 2026 AND d.month_num BETWEEN 7 AND 9
GROUP BY b.branch_name ORDER BY b.branch_name;

\echo '=== 3.4 nightly data-quality test: milestones in order (must be 0 rows)'
SELECT application_no FROM fact_loan_application
WHERE (docs_verified_date_key < submitted_date_key)
   OR (scored_date_key < docs_verified_date_key AND scored_date_key <> 99991231)
   OR (decision_date_key < scored_date_key AND decision_date_key <> 99991231)
   OR (signed_date_key < decision_date_key AND signed_date_key <> 99991231)
   OR (disbursed_date_key < signed_date_key AND disbursed_date_key <> 99991231)
   OR (disbursed_date_key <> 99991231 AND signed_date_key = 99991231)   -- cannot disburse before signing
   OR days_approval_to_disbursement < 0;
