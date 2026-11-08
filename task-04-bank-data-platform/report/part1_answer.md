# Part 1: Dimensional model for transactions and balances

## 1.1 Why one fact table cannot serve Questions 1 and 2

Question 1 (daily net inflow) counts **events**: every deposit, withdrawal or transfer is a row, and we add up the amounts. This needs a **transaction fact table** (a transaction grain fact).

Question 2 (average monthly balance) is about a **state**: how much money a customer has at a point in time. A balance is not an event. On a day with no transaction there is no row in the transaction table, but the customer still has a balance. This needs a **periodic snapshot fact table** with one row per account per day.

If we tried to answer Question 2 from the transaction table we would have to replay every transaction since the account was opened. Days without activity would be missing from the average. If we tried to answer Question 1 from the balance table we could only get the change between two days, and we would lose the type, channel and time of each transaction.

## 1.2 Grain, dimensions and facts

### fact_transaction

**Grain:** one posting leg, meaning one account affected by one transaction.

| Dimensions | Facts | Type |
|---|---|---|
| dim_date, dim_account, dim_customer, dim_branch, dim_txn_type, dim_channel | amount_uzs (signed) | additive |
| degenerate: transaction_id, leg_no | fee_uzs | additive |
| | txn_count (always 1) | additive |
| | fx_rate_to_uzs | non-additive |

### fact_daily_balance

**Grain:** one account per calendar day (end-of-day balance).

| Dimensions | Facts | Type |
|---|---|---|
| dim_date, dim_account, dim_customer, dim_branch | closing_balance_uzs | **semi-additive** (add across accounts, never across days) |
| | accrued_interest_uzs | additive |
| | interest_rate | non-additive |

Assumption: all amounts are converted to UZS in the load, and the original currency stays in dim_account.

## 1.3 Transfers: one row or two?

**Decision: two rows (one per leg)**, with the same `transaction_id` and `leg_no` 1 and 2. The amount is signed: negative for the debited account, positive for the credited account.

Reasons:
- Each leg has its own account, customer, branch and region. One row would need two copies of every dimension key (role-playing `from_` and `to_` keys), and every regional query would need a UNION of both roles.
- Because the grain is "one account affected", `SUM(amount_uzs)` by any dimension is always correct.
- A simple test proves nothing is lost: the legs of one transaction must sum to 0.

Alternative rejected: one row with `from_account_key` and `to_account_key`. It is closer to the source file, but it makes regional sums harder and easy to get wrong.

Example (data in `part1_model.sql`): on 2026-03-02 a customer deposits 50 in Tashkent. On 2026-03-03 a customer sends 100 from Tashkent to Samarkand.

| Check | Result |
|---|---|
| Net inflow, Tashkent city | +50 − 100 = **−50** |
| Net inflow, Samarkand | **+100** |
| Net inflow, whole bank | **+50** (the transfer cancels out, only the real cash deposit remains) |
| Total deposits, Tashkent city (balance table) | 3,000 → 2,950, change **−50** |
| Total deposits, Samarkand (balance table) | 500 → 600, change **+100** |

The change in total deposits equals the net inflow in every region, so both measures agree.

## 1.4 Average monthly balance per customer

```sql
WITH customer_day AS (
    SELECT customer_key, date_key, SUM(closing_balance_uzs) AS balance
    FROM fact_daily_balance
    GROUP BY customer_key, date_key
)
SELECT c.client_no, d.year, d.month_num, ROUND(AVG(cd.balance), 2) AS avg_monthly_balance
FROM customer_day cd
JOIN dim_date d     ON d.date_key = cd.date_key
JOIN dim_customer c ON c.customer_key = cd.customer_key
GROUP BY c.client_no, d.year, d.month_num;
```

The first step adds a customer's accounts for each day (balances are additive across accounts). The second step averages over the days of the month. Result for March 2026: 954.84, 593.55 and 1,883.87.

**Why AVG and not SUM:** a balance is a *level*, not a *flow*. A customer who holds 1,000 for 31 days does not own 31,000. Summing over days gives 29,600 for the first customer instead of 954.84. That is why the balance is **semi-additive**: it can be summed across accounts, but over time it must be averaged (or taken at the last day).

Warning: averaging the raw table directly would give the average per *account-day*, not per customer-day. That is why the CTE comes first.

## 1.5 Size of fact_daily_balance and how to keep it affordable

Estimate (assumption: 1.8 million retail + 40,000 business customers, 1.5 accounts each):
- Customers only: 1.84 M × 730 days ≈ **1.3 billion rows**.
- Accounts: 1.84 M × 1.5 = 2.76 M accounts × 730 ≈ **2.0 billion rows**.

**Proposal: store a row only when the balance changes** (valid from, valid to, balance), instead of one row for every day. The average monthly balance is then a time-weighted average: `SUM(balance × days) / days_in_month`. I tested this on the sample data and it gives exactly the same result as the daily table (954.84, 593.55, 1,883.87). In the sample only 7 of 93 daily rows are real changes (about 8%). If 10–20% of account-days have a change, the table drops to roughly 0.2–0.4 billion rows. Daily rows can still be rebuilt from the intervals with `generate_series` when needed.

Alternatives considered:
- *Keep only month-end balances* (about 66 M rows for 24 months): cheap, but it cannot answer Question 2, because the average needs every day.
- *Keep the full daily table but compress and partition it by month in Parquet*: works and is simple, but it still scans billions of rows. It can be combined with the proposal above.
