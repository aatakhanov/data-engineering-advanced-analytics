# Part 5: Pipeline, quality and compliance

## 5.1 Incremental load of the core-banking file

**Key used for deduplication:** `(transaction_id, leg_no)`. It is the natural grain of `fact_transaction` and has a UNIQUE constraint.

**Steps:**
1. **Land** the file untouched in a staging table, tagged with `file_id`. Register the file in `load_log`. If the same `file_id` arrives again, the load stops ("skipped: file already loaded"). This covers (a): nothing is loaded twice.
2. **Deduplicate inside the file:** keep only the last row for each key.
3. **Compare with the fact table:** rows that do not exist are inserted; rows that exist with the same amount are ignored; rows with a different amount are corrections.
4. **Corrections (b):** the old amount is first copied to `fact_transaction_audit` (old value, new value, file, time), then the fact row is **updated in place**.
5. **Aggregates (c):** only the days that really changed (new rows or corrections) are recomputed in `agg_daily_inflow` (net inflow by day, region and segment). Yesterday's totals are ready shortly after the load, well before 08:00. A freshness check at 07:00 alerts the team if they are not.

**Tested:** file F1 inserted 3 rows. File F2 (new day, one correction 500 → 450 for an earlier day, one duplicated line, one re-sent unchanged row) gave `inserted=2 corrected=1 unchanged=1 duplicates_in_file=1`. The aggregate of the earlier day then showed 450, not 500. Loading F2 again changed nothing.

**Update, delete-and-insert, or version?** I chose **update in place + audit table**.
- *Delete-and-insert* gives the same final numbers, but the fact row gets a new surrogate id, and the old value is lost unless it is logged separately.
- *Versioning the fact rows* (`is_current`) keeps history, but every query on 9 million rows a day must then filter on the flag, and one forgotten filter double-counts the correction. With only 0.5% corrections, a separate small audit table gives the same audit trail without that risk.

## 5.2 Streaming for Question 3

**Pipeline:** card processor → **Kafka topic** `card.events` → **stream processor** (for example Flink or Spark Structured Streaming) → **serving table** `rt_card_decline_minute` → dashboard.

- **What is aggregated where:** the stream processor groups events into 1-minute windows by event time and `merchant_category`, and counts `approved` and `declined`. The dashboard reads the small table and sums the minutes to the hour: `declined_share = SUM(declined) / SUM(total)`. Keeping only counts (not ratios) lets any hour or any period be combined correctly, because ratios cannot be added.
- **Event schema:** `event_id` (unique), `event_ts` (event time), `card_token` (token, never the PAN), `merchant_id`, `merchant_category`, `amount`, `currency`, `status` (approved or declined), `response_code`, `decline_reason`, `channel`, `schema_version`.
- **Latency:** a 1-minute window plus a 2-minute watermark gives results within about 3 to 4 minutes, inside the 5-minute target.
- **Duplicates:** the processor drops repeated `event_id` values (state kept for about one hour). The result of each window is written as a full replacement of the row `(window_start, merchant_category)`, so replays do not double-count.
- **Late events:** events inside the watermark are included. Later ones go to a `late` topic. The nightly batch recomputes the whole day from the raw events in Kafka/Parquet and replaces the streaming numbers, so the final figures are exact.

**Why not stream the core-banking file:** it arrives as one file at 01:00 with end-of-day data, so there are no events to stream, and the answer is only needed by 08:00. It also contains corrections of older days and balances "as of end of day", which suit a batch load with reconciliation. Streaming would add servers, state and failure modes without making any answer arrive earlier.

## 5.3 Five data-quality tests

| # | Category | Test (must return 0 rows) | When it fails |
|---|---|---|---|
| 1 | Grain | `SELECT transaction_id, leg_no, COUNT(*) FROM fact_transaction GROUP BY 1,2 HAVING COUNT(*) > 1` | **Stop** the load and roll back the batch: duplicates would inflate every total. |
| 2 | Referential integrity | `SELECT f.txn_leg_id FROM fact_transaction f LEFT JOIN dim_customer c ON c.customer_key = f.customer_key WHERE c.customer_key IS NULL` | Rows with a missing dimension are **moved to quarantine and mapped to the Unknown member (-1)**; the load continues and an alert is sent to the data owner. |
| 3 | No overlapping Type 2 rows | `SELECT a.client_no FROM dim_customer a JOIN dim_customer b ON a.client_no = b.client_no AND a.customer_key <> b.customer_key AND a.valid_from < b.valid_to AND b.valid_from < a.valid_to` | **Stop** the dimension load and keep yesterday's version of the dimension: overlapping rows would double-count facts. |
| 4 | Reconciliation | Compare the control record of each file (row count and total amount) with what was loaded: `... WHERE c.row_count <> d.rows_loaded OR c.total_amount <> d.amount_loaded` | **Do not publish** the day. The previous day's aggregates stay visible, a ticket is raised, and the file is requested again from core banking. |
| 5 | Freshness | `SELECT MAX(loaded_at) FROM load_log HAVING now() - MAX(loaded_at) > INTERVAL '26 hours'` (run at 07:00) | **Alert** the on-duty engineer; dashboards show a "data is stale" banner so that nobody reads old figures as current. |

All five were run on the test data. The first four returned 0 rows. The freshness test returned 0 rows at 08:00 on the day after the load and 1 row two days later, so it detects a missing load.

## 5.4 Personal data and localisation

**Legal check (done on 2026-11-08, from secondary sources only).** The Law "On Personal Data" (No. ZRU-547 of 2 July 2019) had, since April 2021, required personal data of Uzbek citizens to be processed on servers physically in Uzbekistan (Article 27-1). Law firms and news sites report that **amendments adopted in March 2026** narrowed this: mandatory local storage now applies to biometric data, genetic data and subscriber data of telecom operators, and other personal data may be processed abroad if conditions are met. A resolution of 29 July 2026 lists 49 countries recognised as adequate for simplified transfers. I could not open the official text on lex.uz, so the **exact wording must be confirmed there** before submission. I also did not verify banking-specific rules (bank secrecy and Central Bank regulations), which may be stricter than the general law.

**Design decision:** even if the general law no longer forces it for PINFL or phone numbers, Zarafshon Bank keeps **all personal data inside Uzbekistan**. Reasons: Question 6 asks for exactly that proof, KYC may hold biometric data (which is mandatory local), the bank may have stricter sector rules, and one simple rule is easier to prove and audit than category-by-category exceptions.

| Data | Where it is stored | Who can query it | How analysts still join customers |
|---|---|---|---|
| **PINFL** | `hub_customer.pinfl` in the **restricted zone** of the vault (encrypted column) | KYC/compliance officers only, with logged access | Through `customer_hk`, a **keyed hash** (HMAC with a secret key kept in the bank's key vault). Plain MD5 as in my demo is not safe for production, because the 14-digit PINFL space can be brute-forced. |
| **Passport number** | `sat_kyc_customer`, restricted zone, encrypted | Compliance only | Not needed for joins; never copied to the star schema. |
| **Full name** | `sat_kyc_customer` and a separate `dim_customer_pii` table (restricted) | Compliance and customer service roles | Analysts use `customer_key`; a view with masked name (initials) exists for support. |
| **Phone number** | `sat_app_customer` (restricted), masked copy in the star schema | Marketing and support through a masked view (last 4 digits); full number only with approval | `customer_key`, or a tokenised phone value if matching is needed. |

**Zones:** (1) *Restricted raw zone*, which holds identifiers and is encrypted; (2) *business vault and star schema*, which hold only surrogate keys and non-identifying attributes (segment, region, risk rating); (3) *data marts and dashboards*, with no direct identifiers at all. Access is by role, with column masking, row-level rules for branch staff, and an audit log of every query on the restricted zone.

**Evidence for the Central Bank (Question 6):** (1) the list of servers and storage with their physical address and the data-centre contract/certificate; (2) cloud or hosting configuration showing only Uzbekistan regions, including **backups and disaster recovery**; (3) network diagrams and firewall rules showing no route that sends restricted data abroad, plus egress logs; (4) a statement of where encryption keys live (in the country); (5) access logs proving that administrators work from approved locations; (6) the registration of the databases where the law requires it; (7) an internal audit report repeated every year.

## 5.5 Cost and operations

- **Daily volume:** 9,000,000 rows × 200 bytes = **1.8 GB per day** before compression.
- **Yearly raw:** 1.8 GB × 365 = **657 GB**.
- **Parquet at 5× compression:** 657 / 5 = **about 131 GB per year**.

**Partitioning:** partition the fact by transaction date (daily partitions, or monthly for older data), so a daily load and a correction touch one partition and Question 1 reads one partition. Inside each partition sort or cluster by `branch_key`.
**Retention (assumption, to be confirmed with the bank's legal team):** keep detailed transactions for 5 years, the last 24 months on fast storage and older months on cheaper storage; keep daily aggregates and balance snapshots longer. At about 131 GB a year, 5 years of detail is under 1 TB compressed, which is small.

**Monitoring alert:** *row-count anomaly on the daily load.* If the number of rows loaded for yesterday differs by more than 30% from the average of the same weekday in the last four weeks (or the load has not finished by 05:00), page the on-call engineer. It catches an empty, truncated or doubled file before 08:00.
