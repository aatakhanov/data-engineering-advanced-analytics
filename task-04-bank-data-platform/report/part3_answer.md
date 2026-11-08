# Part 3: Loan lifecycle

## 3.1 fact_loan_application (accumulating snapshot)

**Grain:** one loan application, one row for its whole life. The row is created when the application is submitted and updated every time it moves to the next step.

**Date keys (one per milestone, all pointing to the same dim_date, so they are role-playing dimensions):**
`submitted_date_key`, `docs_verified_date_key`, `scored_date_key`, `decision_date_key` (approved or rejected), `signed_date_key`, `disbursed_date_key`, `withdrawn_date_key`.
A milestone that has not happened yet points to a special "not yet" row of dim_date (key 99991231). It is never NULL, so joins do not drop rows.

**Precomputed lag measures (in days, NULL until both milestones exist):**
`days_submit_to_docs`, `days_docs_to_scored`, `days_scored_to_decision`, `days_decision_to_signed`, `days_signed_to_disbursed`, `days_approval_to_disbursement`, `days_total_to_disbursement`.
These answer "where do applications stall?" with a simple AVG per step (result: mortgages wait longest, 9.0 days to verify documents and 13.0 days from signing to disbursement).

**Dimensions:** dim_customer (Type 2 key chosen on the submission date), dim_branch, dim_loan_product, dim_employee (the employee responsible now), dim_loan_stage (current stage, with a flag for terminal stages), and the seven role-playing dates.
**Degenerate dimension:** `application_no`.

**Other facts:** requested, approved and disbursed amounts (additive), credit score (non-additive).

Design choice: the age of an open application ("days waiting so far") is **not stored**. It would change every night for every open application and force a rewrite. It is computed at query time from `last_event_ts`.

## 3.2 Nightly load

1. **Detect changes.** The load keeps a watermark (`last_loaded_at`). It selects only the applications that have at least one source event with `loaded_at` after the watermark. Normally this is a few percent of all rows.
2. **Rebuild only those applications.** For each changed application, all of its events are aggregated again (first date per milestone, last stage, last employee, amounts).
3. **MERGE by application_no.** If the row exists, update: the milestone date keys, current stage, responsible employee, amounts, score, lags and `last_event_ts`. If it does not exist, insert it. The dimension keys (customer, branch, product) are fixed when the application is submitted and are not updated.
4. **Move the watermark** in the same transaction.

**How we avoid touching 2 million historical rows:** the source events are filtered by the watermark first, so closed applications never enter the join. The fact table can also be partitioned by submission month, so a MERGE on recent months does not scan old partitions. Terminal applications are frozen after a grace period (for example 90 days) and a late correction on them goes through a controlled reload.

Tested result: night 1 loaded 10 applications; night 2 touched only 2 rows (one update, one insert) out of 11; running night 2 again touched 0 rows, so the load is idempotent (safe to re-run).

## 3.3 Stage counts at the end of every month

The accumulating snapshot keeps only the *current* state and one date per milestone. It can be used to rebuild past stage counts, but badly:
- It needs a long CASE expression over seven date columns for every month end (I wrote it in `part3_queries.sql`).
- It guesses the stage. For example, an application that was approved and then withdrawn is shown as "withdrawn" only from the withdrawal date, and the "rejected vs approved" outcome is taken from the current stage.
- If a date is corrected later, past months silently change, so a published trend chart no longer matches.
- It rescans all applications for every month.

**Second table: `fact_loan_stage_month`, a periodic snapshot.** Grain: one stage per branch per product per month end. Facts: `application_count` (semi-additive: add across branches and products, never across months), `amount_uzs`. A job inserts the counts on the last day of each month and never changes them afterwards, so the trend chart is stable and fast. (Another option is an event table with one row per stage entry; it can feed both tables, but it is bigger.)

## 3.4 Median days from approval to disbursement, by branch, Q3 2026

Assumption: "Q3" means the loan was **disbursed** in Q3 (July to September).

```sql
SELECT b.branch_name,
       COUNT(*) AS loans,
       PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY f.days_approval_to_disbursement) AS median_days
FROM fact_loan_application f
JOIN dim_branch b ON b.branch_key = f.branch_key
JOIN dim_date d   ON d.date_key = f.disbursed_date_key
WHERE d.year = 2026 AND d.month_num BETWEEN 7 AND 9
GROUP BY b.branch_name;
```

Result on the test data: Chilonzor 10 days (3 loans), Registan 11 days (3 loans). A loan disbursed on 5 October is correctly excluded. `AVG` would be misleading here because a few very slow mortgages pull the average up; the median is stable.

**Nightly data-quality test:** milestones must be in order. No row may have a later milestone dated before an earlier one, and a loan cannot be disbursed without a signing date:

```sql
SELECT application_no FROM fact_loan_application
WHERE docs_verified_date_key < submitted_date_key
   OR (scored_date_key < docs_verified_date_key AND scored_date_key <> 99991231)
   OR (decision_date_key < scored_date_key AND decision_date_key <> 99991231)
   OR (signed_date_key < decision_date_key AND signed_date_key <> 99991231)
   OR (disbursed_date_key < signed_date_key AND disbursed_date_key <> 99991231)
   OR (disbursed_date_key <> 99991231 AND signed_date_key = 99991231)
   OR days_approval_to_disbursement < 0;
```

It must return 0 rows. If it returns rows, the pipeline sends the bad applications to a quarantine table, raises an alert for the data owner, and still publishes the rest of the table.
