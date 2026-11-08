-- Part 5: incremental load, quality tests, cost
SET search_path TO bank;
DROP TABLE IF EXISTS stg_core_txn, load_log, fact_transaction_audit, agg_daily_inflow, src_control CASCADE;

-- Immutable landing area: every row of every file is kept as received
CREATE TABLE stg_core_txn (
    row_seq        BIGSERIAL PRIMARY KEY,          -- order of arrival
    file_id        TEXT NOT NULL,
    transaction_id TEXT NOT NULL,
    leg_no         SMALLINT NOT NULL,
    date_key       INTEGER NOT NULL,
    account_key    INTEGER NOT NULL,
    customer_key   INTEGER NOT NULL,
    branch_key     INTEGER NOT NULL,
    txn_type_key   INTEGER NOT NULL,
    channel_key    INTEGER NOT NULL,
    amount_uzs     NUMERIC(18,2) NOT NULL
);
CREATE TABLE src_control (file_id TEXT PRIMARY KEY, row_count INTEGER NOT NULL, total_amount NUMERIC(18,2) NOT NULL);
CREATE TABLE load_log (
    file_id TEXT PRIMARY KEY, loaded_at TIMESTAMP NOT NULL,
    rows_inserted INT, rows_corrected INT, rows_unchanged INT, rows_duplicate INT
);
-- Old values of corrected rows (audit trail)
CREATE TABLE fact_transaction_audit (
    txn_leg_id BIGINT, old_amount_uzs NUMERIC(18,2), new_amount_uzs NUMERIC(18,2),
    changed_by_file TEXT, changed_at TIMESTAMP DEFAULT now()
);
-- Pre-aggregate for Question 1 (net inflow by day, region, segment)
CREATE TABLE agg_daily_inflow (
    date_key INTEGER, region TEXT, segment TEXT, net_inflow_uzs NUMERIC(18,2),
    PRIMARY KEY (date_key, region, segment)
);

CREATE OR REPLACE FUNCTION rebuild_agg(p_dates INTEGER[]) RETURNS VOID LANGUAGE sql AS $$
    DELETE FROM agg_daily_inflow WHERE date_key = ANY(p_dates);
    INSERT INTO agg_daily_inflow
    SELECT f.date_key, b.region, c.segment, SUM(f.amount_uzs)
    FROM fact_transaction f
    JOIN dim_branch b   ON b.branch_key = f.branch_key
    JOIN dim_customer c ON c.customer_key = f.customer_key
    WHERE f.date_key = ANY(p_dates)
    GROUP BY f.date_key, b.region, c.segment;
$$;

CREATE OR REPLACE FUNCTION load_core_file(p_file TEXT, p_now TIMESTAMP) RETURNS TEXT
LANGUAGE plpgsql AS $$
DECLARE n_dup INT; n_ins INT; n_upd INT; n_same INT; v_dates INTEGER[];
BEGIN
    -- (a) never load a file twice
    IF EXISTS (SELECT 1 FROM load_log WHERE file_id = p_file) THEN RETURN 'skipped: file already loaded'; END IF;

    -- latest version of each (transaction_id, leg_no) inside the file
    CREATE TEMP TABLE batch ON COMMIT DROP AS
    SELECT DISTINCT ON (transaction_id, leg_no) *
    FROM stg_core_txn WHERE file_id = p_file
    ORDER BY transaction_id, leg_no, row_seq DESC;
    SELECT (SELECT COUNT(*) FROM stg_core_txn WHERE file_id = p_file) - COUNT(*) INTO n_dup FROM batch;

    -- days that really change: new rows or corrected amounts (computed BEFORE we modify the fact)
    SELECT ARRAY_AGG(DISTINCT s.date_key) INTO v_dates FROM batch s
     WHERE NOT EXISTS (SELECT 1 FROM fact_transaction f
                        WHERE f.transaction_id = s.transaction_id AND f.leg_no = s.leg_no
                          AND f.amount_uzs = s.amount_uzs);

    -- (b) corrections: keep the old value in the audit table, then update in place
    INSERT INTO fact_transaction_audit (txn_leg_id, old_amount_uzs, new_amount_uzs, changed_by_file)
    SELECT f.txn_leg_id, f.amount_uzs, s.amount_uzs, p_file
    FROM batch s JOIN fact_transaction f USING (transaction_id, leg_no)
    WHERE f.amount_uzs <> s.amount_uzs;
    GET DIAGNOSTICS n_upd = ROW_COUNT;

    UPDATE fact_transaction f SET amount_uzs = s.amount_uzs
    FROM batch s WHERE f.transaction_id = s.transaction_id AND f.leg_no = s.leg_no
      AND f.amount_uzs <> s.amount_uzs;

    SELECT COUNT(*) INTO n_same FROM batch s JOIN fact_transaction f USING (transaction_id, leg_no)
     WHERE f.amount_uzs = s.amount_uzs;

    INSERT INTO fact_transaction (transaction_id, leg_no, date_key, txn_ts, account_key, customer_key,
                                  branch_key, txn_type_key, channel_key, amount_uzs)
    SELECT s.transaction_id, s.leg_no, s.date_key, TO_DATE(s.date_key::TEXT,'YYYYMMDD'), s.account_key,
           s.customer_key, s.branch_key, s.txn_type_key, s.channel_key, s.amount_uzs
    FROM batch s
    WHERE NOT EXISTS (SELECT 1 FROM fact_transaction f WHERE f.transaction_id = s.transaction_id AND f.leg_no = s.leg_no);
    GET DIAGNOSTICS n_ins = ROW_COUNT;
    n_same := n_same - n_upd;

    -- (c) rebuild the aggregate ONLY for the days that changed (new rows or corrections)
    IF v_dates IS NOT NULL THEN PERFORM rebuild_agg(v_dates); END IF;

    INSERT INTO load_log VALUES (p_file, p_now, n_ins, n_upd, n_same, n_dup);
    RETURN format('inserted=%s corrected=%s unchanged=%s duplicates_in_file=%s', n_ins, n_upd, n_same, n_dup);
END $$;

-- ---------- Test files ----------
-- File F1 (2026-11-02 01:00): 3 transactions of 2026-11-01
INSERT INTO stg_core_txn (file_id, transaction_id, leg_no, date_key, account_key, customer_key, branch_key, txn_type_key, channel_key, amount_uzs)
VALUES ('F1','N-1',1,20261101,1,1,1,1,1, 500), ('F1','N-2',1,20261101,2,2,3,1,1, 300), ('F1','N-3',1,20261101,3,3,2,2,2,-120);
INSERT INTO src_control VALUES ('F1', 3, 680);

-- File F2 (2026-11-03 01:00): new day + a CORRECTION of N-1 (500 -> 450) + a duplicate line + an unchanged re-send
INSERT INTO stg_core_txn (file_id, transaction_id, leg_no, date_key, account_key, customer_key, branch_key, txn_type_key, channel_key, amount_uzs)
VALUES ('F2','N-4',1,20261102,1,1,1,1,1, 200),
       ('F2','N-4',1,20261102,1,1,1,1,1, 200),          -- duplicate line in the same file
       ('F2','N-5',1,20261102,2,2,3,2,2, -50),
       ('F2','N-1',1,20261101,1,1,1,1,1, 450),          -- correction of an earlier day
       ('F2','N-2',1,20261101,2,2,3,1,1, 300);          -- re-sent, unchanged
INSERT INTO src_control VALUES ('F2', 4, 900);          -- distinct rows 200 -50 450 300 = 900
