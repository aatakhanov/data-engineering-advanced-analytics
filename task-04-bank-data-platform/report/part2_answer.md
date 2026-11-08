# Part 2: Customer history and slowly changing dimensions

## 2.1 SCD type for each attribute

| Attribute | SCD type | Reason |
|---|---|---|
| Branch of record | **Type 2** | Question 5 asks for the full branch history, and branch reports must show a transaction under the branch the customer belonged to at that time. |
| Segment | **Type 2** | Question 5 asks for it. Segment is used to group inflows, so history must not be rewritten when a customer is upgraded. |
| Risk rating | **Type 2** | Compliance must know the rating at the time of each transaction (see 2.3), and the Central Bank audits it. |
| Phone number | **Type 1** | Changes often and nobody analyses old numbers. Overwrite it. The full history of phone numbers stays in the raw vault (Part 4). |
| Date of first account | **Type 0** | It never changes. If a correction arrives, it fixes an error, so we keep the original loaded value and handle corrections as data-quality issues. |
| Relationship manager | **Type 1** | It is not needed for Question 5, and staff changes can reassign thousands of customers at once. As Type 2 this would create thousands of new rows for nothing. The history stays in the CRM satellite. If management later wants "sales by manager at the time", use a separate small mini-dimension or a bridge table instead of adding it to dim_customer. |

## 2.2 Rows for customer 4471

Assumption: she is a customer from 2024-01-01 with branch Chilonzor, segment mass, risk low. Branch and segment both changed on 2026-03-12, so they share **one** new version (two changes on the same date do not need two rows).

| customer_key | branch | segment | risk_rating | valid_from | valid_to | is_current |
|---|---|---|---|---|---|---|
| 4 | Chilonzor | mass | low | 2024-01-01 | 2026-03-12 | false |
| 5 | Yunusobod | affluent | low | 2026-03-12 | 2026-04-02 | false |
| 6 | Yunusobod | affluent | medium | 2026-04-02 | 9999-12-31 | true |

**On 2026-04-05, 3 rows exist for her, and exactly 1 row is valid** (key 6, which is also the current row). The validity intervals are half-open (`valid_from <= date < valid_to`), so they never overlap and no date belongs to two rows.

## 2.3 Which transactions were made while she was rated high risk?

```sql
SELECT f.transaction_id, f.date_key, f.amount_uzs
FROM fact_transaction f
JOIN dim_customer c ON c.customer_key = f.customer_key
WHERE c.client_no = 4471
  AND c.risk_rating = 'high';
```

(In my test data she is never rated high, so I ran the same query with `'medium'`: it returns the two transactions on 2026-04-03 and 2026-04-10.)

**Why it is easy:** the fact row stores the surrogate key of the version that was valid when it was loaded. That key already points to the right risk rating, so the answer is a plain join with a filter. No date logic is needed.

**If the fact had only client_no:** every query would need a date-range join:

```sql
JOIN dim_customer c ON c.client_no = f.client_no
 AND f.txn_date >= c.valid_from AND f.txn_date < c.valid_to
```

This gives the same result (I tested it), but it is slower on billions of rows, because the join cannot use a simple key lookup. It is also easy to get wrong: a forgotten upper bound or overlapping intervals silently duplicates or drops transactions, and every analyst must remember the rule.

## 2.4 Late-arriving CRM change

**Situation:** the change effective 2026-03-12 arrives on 2026-03-14. The transactions of 2026-03-12 and 2026-03-13 were already loaded with the old version (mass, Chilonzor).

**What the load must do (in one database transaction):**
1. Find the version that contains the effective date (2026-03-12).
2. Shorten it: set its `valid_to` to 2026-03-12.
3. Insert the new version from 2026-03-12 until the old `valid_to`, copying every attribute that did not change.
4. Re-key the facts: for that customer, every fact with a date on or after 2026-03-12 that points to the old version is updated to the new key (and branch).
5. Write a line to an audit log (client_no, effective date, rows re-keyed, file name, load time).

Transactions loaded on 2026-03-13 are therefore **corrected** and appear under the affluent segment and Yunusobod branch. Transactions before 2026-03-12 are not touched. I tested this: transaction T-11 (2026-03-13) moved from key 4 to key 5, while T-10 (2026-03-05) stayed on key 4.

**Pipeline rule:** "A dimension change is applied with its *effective date*, never with its arrival date. If it falls inside an existing version, split that version and re-key the affected facts. The load is idempotent: loading the same file twice changes nothing."

**Rejected alternatives:**
- *Apply the change from the arrival date (2026-03-14).* The history of 12 to 13 March would be wrong, which is not acceptable for an audited bank.
- *Hold all facts for two days until the CRM file arrives.* It would break the 08:00 deadline for Question 1.

If a fact arrives for a customer that does not exist yet, load it with an inferred member (key -1 or a placeholder row) and fix it when the dimension row arrives, in the same way.
