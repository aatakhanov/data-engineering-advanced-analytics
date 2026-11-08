-- Part 2: customer history (SCD Type 2), late-arriving changes, compliance query
SET search_path TO bank;

-- Helper: surrogate key valid on a date (-1 if not found)
CREATE OR REPLACE FUNCTION customer_key_on(p_client_no BIGINT, p_date DATE)
RETURNS INTEGER LANGUAGE sql STABLE AS $$
    SELECT COALESCE((SELECT customer_key FROM dim_customer
                      WHERE client_no = p_client_no
                        AND p_date >= valid_from AND p_date < valid_to), -1);
$$;

-- One current row per client_no
CREATE UNIQUE INDEX IF NOT EXISTS ux_customer_current ON dim_customer (client_no) WHERE is_current;

-- Apply a change effective on a given date. NULL parameter = attribute unchanged.
-- Works for normal AND late-arriving changes: it splits the version that contains
-- the effective date and re-keys the facts that were loaded with the old version.
CREATE OR REPLACE FUNCTION apply_customer_change(
    p_client_no BIGINT, p_effective DATE,
    p_segment TEXT DEFAULT NULL, p_branch_code TEXT DEFAULT NULL, p_risk TEXT DEFAULT NULL)
RETURNS VOID LANGUAGE plpgsql AS $$
DECLARE
    old_row dim_customer%ROWTYPE;
    new_key INTEGER;
    new_branch INTEGER;
BEGIN
    SELECT * INTO old_row FROM dim_customer
     WHERE client_no = p_client_no AND p_effective >= valid_from AND p_effective < valid_to
     FOR UPDATE;
    IF NOT FOUND THEN RAISE EXCEPTION 'no version of % covers %', p_client_no, p_effective; END IF;
    IF old_row.valid_from = p_effective THEN
        RAISE EXCEPTION 'version already starts on % - update it instead', p_effective;
    END IF;

    SELECT COALESCE((SELECT branch_key FROM dim_branch WHERE branch_code = p_branch_code), old_row.branch_key)
      INTO new_branch;

    -- 1) shorten the old version (it keeps its row, just ends earlier)
    UPDATE dim_customer SET valid_to = p_effective, is_current = FALSE
     WHERE customer_key = old_row.customer_key;

    -- 2) insert the new version for [effective, old valid_to)
    INSERT INTO dim_customer (client_no, segment, risk_rating, branch_key, valid_from, valid_to, is_current)
    VALUES (p_client_no, COALESCE(p_segment, old_row.segment), COALESCE(p_risk, old_row.risk_rating),
            new_branch, p_effective, old_row.valid_to, old_row.is_current)
    RETURNING customer_key INTO new_key;

    -- 3) re-key facts that already used the old version on or after the effective date
    UPDATE fact_transaction
       SET customer_key = new_key, branch_key = new_branch
     WHERE customer_key = old_row.customer_key
       AND date_key >= TO_CHAR(p_effective, 'YYYYMMDD')::INT;
END $$;

-- ---------- Scenario for customer 4471 ----------
-- Assumption: she became a customer on 2024-01-01 (Chilonzor, mass, low risk).
INSERT INTO dim_customer (client_no, segment, risk_rating, branch_key, valid_from)
SELECT 4471, 'mass', 'low', branch_key, DATE '2024-01-01' FROM dim_branch WHERE branch_code = 'B-001';

INSERT INTO dim_account (account_no, product_type, currency, customer_key, branch_key)
SELECT 'A4', 'current', 'UZS', customer_key_on(4471, '2024-01-01'), 1 FROM dim_branch LIMIT 1;

-- Transactions loaded as they arrive, using the version known at load time
INSERT INTO fact_transaction (transaction_id, leg_no, date_key, txn_ts, account_key, customer_key,
                              branch_key, txn_type_key, channel_key, amount_uzs)
SELECT v.tid, 1, v.dk, v.ts::TIMESTAMP, a.account_key, customer_key_on(4471, TO_DATE(v.dk::TEXT,'YYYYMMDD')),
       1, t.txn_type_key, c.channel_key, v.amt
FROM (VALUES ('T-10',20260305,'2026-03-05 09:00',200),
             ('T-11',20260313,'2026-03-13 09:30',100)) AS v(tid,dk,ts,amt)
JOIN dim_account a ON a.account_no = 'A4'
JOIN dim_txn_type t ON t.txn_type = 'cash deposit'
JOIN dim_channel c ON c.channel = 'branch';

\echo '=== before the late CRM file: T-11 (03-13) carries the OLD version'
SELECT f.transaction_id, f.date_key, f.customer_key, c.segment
FROM fact_transaction f JOIN dim_customer c USING (customer_key)
WHERE c.client_no = 4471 ORDER BY f.date_key;

-- 2026-03-14: the CRM file with the 03-12 change (branch + segment) arrives late
BEGIN;
SELECT apply_customer_change(4471, DATE '2026-03-12', 'affluent', 'B-002', NULL);
COMMIT;

\echo '=== after the late file: T-11 is re-keyed, T-10 is untouched'
SELECT f.transaction_id, f.date_key, f.customer_key, c.segment, b.branch_name
FROM fact_transaction f JOIN dim_customer c USING (customer_key) JOIN dim_branch b ON b.branch_key = f.branch_key
WHERE c.client_no = 4471 ORDER BY f.date_key;

-- 2026-04-02: risk rating becomes medium (normal, on-time change)
SELECT apply_customer_change(4471, DATE '2026-04-02', NULL, NULL, 'medium');

-- Later transactions get the newest version at load time
INSERT INTO fact_transaction (transaction_id, leg_no, date_key, txn_ts, account_key, customer_key,
                              branch_key, txn_type_key, channel_key, amount_uzs)
SELECT v.tid, 1, v.dk, v.ts::TIMESTAMP, a.account_key, customer_key_on(4471, TO_DATE(v.dk::TEXT,'YYYYMMDD')),
       2, t.txn_type_key, c.channel_key, v.amt
FROM (VALUES ('T-12',20260403,'2026-04-03 12:00',-50),
             ('T-13',20260410,'2026-04-10 15:20',-75)) AS v(tid,dk,ts,amt)
JOIN dim_account a ON a.account_no = 'A4'
JOIN dim_txn_type t ON t.txn_type = 'card payment'
JOIN dim_channel c ON c.channel = 'card terminal';

\echo '=== 2.2 rows of dim_customer for 4471'
SELECT customer_key, segment, risk_rating, branch_key, valid_from, valid_to, is_current
FROM dim_customer WHERE client_no = 4471 ORDER BY valid_from;

\echo '=== 2.2 rows existing / valid on 2026-04-05'
SELECT COUNT(*) AS rows_total,
       COUNT(*) FILTER (WHERE DATE '2026-04-05' >= valid_from AND DATE '2026-04-05' < valid_to) AS rows_valid_on_that_day
FROM dim_customer WHERE client_no = 4471;

\echo '=== 2.3 transactions made while rated MEDIUM (surrogate key)'
SELECT f.transaction_id, f.date_key, f.amount_uzs
FROM fact_transaction f JOIN dim_customer c ON c.customer_key = f.customer_key
WHERE c.client_no = 4471 AND c.risk_rating = 'medium' ORDER BY f.date_key;

\echo '=== 2.3 same question if the fact had only client_no (date-range join)'
SELECT f.transaction_id, f.date_key, f.amount_uzs
FROM (SELECT t.*, 4471::BIGINT AS client_no FROM fact_transaction t JOIN dim_account a USING (account_key)
       WHERE a.account_no = 'A4') f
JOIN dim_customer c ON c.client_no = f.client_no
 AND TO_DATE(f.date_key::TEXT,'YYYYMMDD') >= c.valid_from
 AND TO_DATE(f.date_key::TEXT,'YYYYMMDD') <  c.valid_to
WHERE c.risk_rating = 'medium' ORDER BY f.date_key;

\echo '=== quality: overlapping versions (must be 0 rows)'
SELECT a.client_no FROM dim_customer a JOIN dim_customer b
  ON a.client_no = b.client_no AND a.customer_key <> b.customer_key
 AND a.valid_from < b.valid_to AND b.valid_from < a.valid_to;
\echo '=== quality: facts pointing to a version not valid on their date (must be 0 rows)'
SELECT f.txn_leg_id FROM fact_transaction f
JOIN dim_date d ON d.date_key = f.date_key
JOIN dim_customer c ON c.customer_key = f.customer_key
WHERE NOT (d.full_date >= c.valid_from AND d.full_date < c.valid_to);
