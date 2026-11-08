-- Part 1: Dimensional model for transactions and balances (Zarafshon Bank)
DROP SCHEMA IF EXISTS bank CASCADE;
CREATE SCHEMA bank;
SET search_path TO bank;

-- ---------- Dimensions ----------
CREATE TABLE dim_date (
    date_key      INTEGER PRIMARY KEY,
    full_date     DATE NOT NULL UNIQUE,
    year          SMALLINT NOT NULL,
    month_num     SMALLINT NOT NULL,
    days_in_month SMALLINT NOT NULL,
    is_month_end  BOOLEAN NOT NULL
);
INSERT INTO dim_date
SELECT TO_CHAR(d,'YYYYMMDD')::INT, d, EXTRACT(YEAR FROM d), EXTRACT(MONTH FROM d),
       EXTRACT(DAY FROM (date_trunc('month', d) + INTERVAL '1 month - 1 day')),
       d = (date_trunc('month', d) + INTERVAL '1 month - 1 day')::DATE
FROM generate_series('2026-01-01'::DATE, '2026-12-31'::DATE, '1 day') d;

CREATE TABLE dim_branch (
    branch_key  SERIAL PRIMARY KEY,
    branch_code TEXT NOT NULL UNIQUE,
    branch_name TEXT NOT NULL,
    region      TEXT NOT NULL
);
INSERT INTO dim_branch (branch_code, branch_name, region) VALUES
('B-001','Chilonzor','Tashkent city'),
('B-002','Yunusobod','Tashkent city'),
('B-010','Registan','Samarkand');

CREATE TABLE dim_customer (
    customer_key SERIAL PRIMARY KEY,
    client_no    BIGINT NOT NULL,              -- natural key (core banking)
    segment      TEXT NOT NULL,                -- mass / affluent / private
    risk_rating  TEXT NOT NULL,
    branch_key   INTEGER NOT NULL REFERENCES dim_branch,
    valid_from   DATE NOT NULL,
    valid_to     DATE NOT NULL DEFAULT '9999-12-31',
    is_current   BOOLEAN NOT NULL DEFAULT TRUE
);
INSERT INTO dim_customer (client_no, segment, risk_rating, branch_key, valid_from) VALUES
(88213, 'mass',     'low', 1, '2020-01-01'),
(91002, 'affluent', 'low', 3, '2020-01-01'),
(93110, 'mass',     'low', 2, '2020-01-01');

CREATE TABLE dim_account (
    account_key  SERIAL PRIMARY KEY,
    account_no   TEXT NOT NULL UNIQUE,
    product_type TEXT NOT NULL,                -- current / savings / term deposit
    currency     CHAR(3) NOT NULL,
    customer_key INTEGER NOT NULL REFERENCES dim_customer,
    branch_key   INTEGER NOT NULL REFERENCES dim_branch
);
INSERT INTO dim_account (account_no, product_type, currency, customer_key, branch_key) VALUES
('A1','current','UZS',1,1),   -- Tashkent, customer 88213
('A2','current','UZS',2,3),   -- Samarkand, customer 91002
('A3','savings','UZS',3,2);   -- Tashkent, customer 93110

CREATE TABLE dim_txn_type (
    txn_type_key SERIAL PRIMARY KEY,
    txn_type     TEXT NOT NULL UNIQUE
);
INSERT INTO dim_txn_type (txn_type) VALUES
('cash deposit'),('cash withdrawal'),('transfer out'),('transfer in'),('card payment'),('fee');

CREATE TABLE dim_channel (
    channel_key SERIAL PRIMARY KEY,
    channel     TEXT NOT NULL UNIQUE
);
INSERT INTO dim_channel (channel) VALUES ('branch'),('atm'),('mobile app'),('card terminal');

-- ---------- Fact 1: transactions ----------
-- Grain: ONE POSTING LEG = one account affected by one transaction.
CREATE TABLE fact_transaction (
    txn_leg_id    BIGSERIAL PRIMARY KEY,
    transaction_id TEXT NOT NULL,              -- degenerate dimension (source id)
    leg_no        SMALLINT NOT NULL,           -- 1 = debited side, 2 = credited side
    date_key      INTEGER NOT NULL REFERENCES dim_date,
    txn_ts        TIMESTAMP NOT NULL,
    account_key   INTEGER NOT NULL REFERENCES dim_account,
    customer_key  INTEGER NOT NULL REFERENCES dim_customer,
    branch_key    INTEGER NOT NULL REFERENCES dim_branch,
    txn_type_key  INTEGER NOT NULL REFERENCES dim_txn_type,
    channel_key   INTEGER NOT NULL REFERENCES dim_channel,
    amount_uzs    NUMERIC(18,2) NOT NULL,      -- signed: + money in, - money out  (additive)
    fee_uzs       NUMERIC(18,2) NOT NULL DEFAULT 0,  -- (additive)
    txn_count     SMALLINT NOT NULL DEFAULT 1, -- (additive)
    fx_rate_to_uzs NUMERIC(12,4) NOT NULL DEFAULT 1, -- (non-additive)
    UNIQUE (transaction_id, leg_no)
);

-- ---------- Fact 2: daily balances ----------
-- Grain: ONE ACCOUNT PER CALENDAR DAY (end-of-day balance).
CREATE TABLE fact_daily_balance (
    date_key       INTEGER NOT NULL REFERENCES dim_date,
    account_key    INTEGER NOT NULL REFERENCES dim_account,
    customer_key   INTEGER NOT NULL REFERENCES dim_customer,
    branch_key     INTEGER NOT NULL REFERENCES dim_branch,
    closing_balance_uzs NUMERIC(18,2) NOT NULL, -- semi-additive (not over time)
    accrued_interest_uzs NUMERIC(18,2) NOT NULL DEFAULT 0, -- additive
    interest_rate  NUMERIC(6,4) NOT NULL,       -- non-additive
    PRIMARY KEY (date_key, account_key)
);

-- ---------- Sample data ----------
-- 03-02: customer 88213 deposits 50 cash into A1 (Tashkent)
-- 03-03: A1 transfers 100 to A2 (Tashkent -> Samarkand): TWO legs, one transaction_id
-- 03-20: customer 93110 withdraws 300 from A3 at an ATM
INSERT INTO fact_transaction (transaction_id, leg_no, date_key, txn_ts, account_key, customer_key,
                              branch_key, txn_type_key, channel_key, amount_uzs)
SELECT v.tid, v.leg, v.dk, v.ts::TIMESTAMP, a.account_key, a.customer_key, a.branch_key,
       t.txn_type_key, c.channel_key, v.amt
FROM (VALUES
 ('T-1',1,20260302,'2026-03-02 10:15','A1','cash deposit','branch',  50),
 ('T-2',1,20260303,'2026-03-03 11:00','A1','transfer out','mobile app',-100),
 ('T-2',2,20260303,'2026-03-03 11:00','A2','transfer in', 'mobile app', 100),
 ('T-3',1,20260320,'2026-03-20 18:40','A3','cash withdrawal','atm',   -300)
) AS v(tid,leg,dk,ts,acc,typ,ch,amt)
JOIN dim_account a ON a.account_no = v.acc
JOIN dim_txn_type t ON t.txn_type = v.typ
JOIN dim_channel c ON c.channel = v.ch;

-- Daily balances for March 2026 = opening balance + cumulative transactions
INSERT INTO fact_daily_balance (date_key, account_key, customer_key, branch_key, closing_balance_uzs, interest_rate)
SELECT d.date_key, a.account_key, a.customer_key, a.branch_key,
       o.opening + COALESCE((SELECT SUM(t.amount_uzs) FROM fact_transaction t
                              WHERE t.account_key = a.account_key AND t.date_key <= d.date_key), 0),
       0.0500
FROM dim_date d
CROSS JOIN dim_account a
JOIN (VALUES ('A1',1000),('A2',500),('A3',2000)) AS o(account_no, opening) ON o.account_no = a.account_no
WHERE d.year = 2026 AND d.month_num = 3;
