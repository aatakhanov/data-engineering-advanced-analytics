-- Part 3: Loan lifecycle - accumulating snapshot fact
SET search_path TO bank;
DROP TABLE IF EXISTS fact_loan_application, src_loan_event, etl_watermark, dim_loan_product, dim_loan_stage, dim_employee CASCADE;

-- "Not yet happened" member of the date dimension
INSERT INTO dim_date VALUES (99991231, '9999-12-31', 9999, 12, 31, TRUE) ON CONFLICT DO NOTHING;

CREATE TABLE dim_loan_product (
    loan_product_key SERIAL PRIMARY KEY,
    product_code TEXT NOT NULL UNIQUE,
    product_name TEXT NOT NULL
);
INSERT INTO dim_loan_product (product_code, product_name) VALUES
('CONS','Consumer loan'),('MORT','Mortgage'),('AUTO','Auto loan');

CREATE TABLE dim_loan_stage (
    stage_key   SERIAL PRIMARY KEY,
    stage_name  TEXT NOT NULL UNIQUE,
    stage_order SMALLINT NOT NULL,
    is_terminal BOOLEAN NOT NULL
);
INSERT INTO dim_loan_stage (stage_name, stage_order, is_terminal) VALUES
('submitted',1,FALSE),('docs_verified',2,FALSE),('scored',3,FALSE),('approved',4,FALSE),
('signed',5,FALSE),('disbursed',6,TRUE),('rejected',7,TRUE),('withdrawn',8,TRUE);

CREATE TABLE dim_employee (
    employee_key SERIAL PRIMARY KEY,
    employee_code TEXT NOT NULL UNIQUE
);
INSERT INTO dim_employee (employee_code) VALUES ('E-01'),('E-02'),('E-03');

-- ---------- Source: one row per step, as core banking records it ----------
CREATE TABLE src_loan_event (
    application_no TEXT NOT NULL,
    stage          TEXT NOT NULL,
    event_ts       TIMESTAMP NOT NULL,
    employee_code  TEXT NOT NULL,
    client_no      BIGINT,            -- filled on 'submitted'
    branch_code    TEXT,              -- filled on 'submitted'
    product_code   TEXT,              -- filled on 'submitted'
    amount_uzs     NUMERIC(18,2),     -- requested / approved / disbursed amount
    credit_score   SMALLINT,          -- filled on 'scored'
    loaded_at      TIMESTAMP NOT NULL,
    PRIMARY KEY (application_no, stage)
);

-- ---------- Accumulating snapshot ----------
-- Grain: ONE LOAN APPLICATION (one row for its whole life, updated as it moves).
CREATE TABLE fact_loan_application (
    application_no          TEXT PRIMARY KEY,                       -- degenerate dimension
    customer_key            INTEGER NOT NULL REFERENCES dim_customer,
    branch_key              INTEGER NOT NULL REFERENCES dim_branch,
    loan_product_key        INTEGER NOT NULL REFERENCES dim_loan_product,
    employee_key            INTEGER NOT NULL REFERENCES dim_employee, -- responsible now
    current_stage_key       INTEGER NOT NULL REFERENCES dim_loan_stage,
    -- one role-playing date key per milestone; 99991231 = not reached yet
    submitted_date_key      INTEGER NOT NULL DEFAULT 99991231 REFERENCES dim_date,
    docs_verified_date_key  INTEGER NOT NULL DEFAULT 99991231 REFERENCES dim_date,
    scored_date_key         INTEGER NOT NULL DEFAULT 99991231 REFERENCES dim_date,
    decision_date_key       INTEGER NOT NULL DEFAULT 99991231 REFERENCES dim_date,  -- approved OR rejected
    signed_date_key         INTEGER NOT NULL DEFAULT 99991231 REFERENCES dim_date,
    disbursed_date_key      INTEGER NOT NULL DEFAULT 99991231 REFERENCES dim_date,
    withdrawn_date_key      INTEGER NOT NULL DEFAULT 99991231 REFERENCES dim_date,
    -- facts
    requested_amount_uzs    NUMERIC(18,2),   -- additive
    approved_amount_uzs     NUMERIC(18,2),   -- additive
    disbursed_amount_uzs    NUMERIC(18,2),   -- additive
    credit_score            SMALLINT,        -- non-additive
    -- precomputed lags in days (NULL until both milestones exist), all additive-as-days
    days_submit_to_docs     INTEGER,
    days_docs_to_scored     INTEGER,
    days_scored_to_decision INTEGER,
    days_decision_to_signed INTEGER,
    days_signed_to_disbursed INTEGER,
    days_approval_to_disbursement INTEGER,
    days_total_to_disbursement INTEGER,
    last_event_ts           TIMESTAMP NOT NULL
);

CREATE TABLE etl_watermark (job TEXT PRIMARY KEY, last_loaded_at TIMESTAMP NOT NULL);
INSERT INTO etl_watermark VALUES ('loan_snapshot', '1900-01-01');

-- ---------- Nightly load: only applications with NEW events are touched ----------
CREATE OR REPLACE FUNCTION load_loan_snapshot(p_run_ts TIMESTAMP)
RETURNS INTEGER LANGUAGE plpgsql AS $$
DECLARE
    v_since TIMESTAMP;
    v_rows  INTEGER;
BEGIN
    SELECT last_loaded_at INTO v_since FROM etl_watermark WHERE job = 'loan_snapshot' FOR UPDATE;

    MERGE INTO fact_loan_application f
    USING (
        WITH changed AS (                     -- applications with at least one new event
            SELECT DISTINCT application_no FROM src_loan_event
             WHERE loaded_at > v_since AND loaded_at <= p_run_ts
        ), a AS (                             -- rebuild the whole life of ONLY those applications
            SELECT e.application_no,
                   MAX(client_no)     FILTER (WHERE stage = 'submitted') AS client_no,
                   MAX(branch_code)   FILTER (WHERE stage = 'submitted') AS branch_code,
                   MAX(product_code)  FILTER (WHERE stage = 'submitted') AS product_code,
                   (MIN(event_ts) FILTER (WHERE stage = 'submitted'))::DATE     AS d_sub,
                   (MIN(event_ts) FILTER (WHERE stage = 'docs_verified'))::DATE AS d_doc,
                   (MIN(event_ts) FILTER (WHERE stage = 'scored'))::DATE        AS d_scr,
                   (MIN(event_ts) FILTER (WHERE stage IN ('approved','rejected')))::DATE AS d_dec,
                   (MIN(event_ts) FILTER (WHERE stage = 'signed'))::DATE        AS d_sig,
                   (MIN(event_ts) FILTER (WHERE stage = 'disbursed'))::DATE     AS d_dis,
                   (MIN(event_ts) FILTER (WHERE stage = 'withdrawn'))::DATE     AS d_wdr,
                   MAX(amount_uzs) FILTER (WHERE stage = 'submitted')  AS req_amt,
                   MAX(amount_uzs) FILTER (WHERE stage = 'approved')   AS apr_amt,
                   MAX(amount_uzs) FILTER (WHERE stage = 'disbursed')  AS dis_amt,
                   MAX(credit_score) AS score,
                   (ARRAY_AGG(stage ORDER BY event_ts DESC, stage))[1]         AS last_stage,
                   (ARRAY_AGG(employee_code ORDER BY event_ts DESC, stage))[1] AS last_emp,
                   MAX(event_ts) AS last_ts
            FROM src_loan_event e JOIN changed c USING (application_no)
            GROUP BY e.application_no
        )
        SELECT a.*,
               customer_key_on(a.client_no, a.d_sub) AS customer_key,
               b.branch_key, p.loan_product_key, em.employee_key, s.stage_key
        FROM a
        JOIN dim_branch b       ON b.branch_code = a.branch_code
        JOIN dim_loan_product p ON p.product_code = a.product_code
        JOIN dim_employee em    ON em.employee_code = a.last_emp
        JOIN dim_loan_stage s   ON s.stage_name = a.last_stage
    ) s ON f.application_no = s.application_no
    WHEN MATCHED THEN UPDATE SET
        employee_key = s.employee_key, current_stage_key = s.stage_key,
        docs_verified_date_key = COALESCE(TO_CHAR(s.d_doc,'YYYYMMDD')::INT, 99991231),
        scored_date_key   = COALESCE(TO_CHAR(s.d_scr,'YYYYMMDD')::INT, 99991231),
        decision_date_key = COALESCE(TO_CHAR(s.d_dec,'YYYYMMDD')::INT, 99991231),
        signed_date_key   = COALESCE(TO_CHAR(s.d_sig,'YYYYMMDD')::INT, 99991231),
        disbursed_date_key= COALESCE(TO_CHAR(s.d_dis,'YYYYMMDD')::INT, 99991231),
        withdrawn_date_key= COALESCE(TO_CHAR(s.d_wdr,'YYYYMMDD')::INT, 99991231),
        approved_amount_uzs = s.apr_amt, disbursed_amount_uzs = s.dis_amt, credit_score = s.score,
        days_submit_to_docs = s.d_doc - s.d_sub, days_docs_to_scored = s.d_scr - s.d_doc,
        days_scored_to_decision = s.d_dec - s.d_scr, days_decision_to_signed = s.d_sig - s.d_dec,
        days_signed_to_disbursed = s.d_dis - s.d_sig,
        days_approval_to_disbursement = s.d_dis - s.d_dec,
        days_total_to_disbursement = s.d_dis - s.d_sub,
        last_event_ts = s.last_ts
    WHEN NOT MATCHED THEN INSERT (
        application_no, customer_key, branch_key, loan_product_key, employee_key, current_stage_key,
        submitted_date_key, docs_verified_date_key, scored_date_key, decision_date_key, signed_date_key,
        disbursed_date_key, withdrawn_date_key, requested_amount_uzs, approved_amount_uzs, disbursed_amount_uzs,
        credit_score, days_submit_to_docs, days_docs_to_scored, days_scored_to_decision,
        days_decision_to_signed, days_signed_to_disbursed, days_approval_to_disbursement,
        days_total_to_disbursement, last_event_ts)
    VALUES (
        s.application_no, s.customer_key, s.branch_key, s.loan_product_key, s.employee_key, s.stage_key,
        COALESCE(TO_CHAR(s.d_sub,'YYYYMMDD')::INT, 99991231), COALESCE(TO_CHAR(s.d_doc,'YYYYMMDD')::INT, 99991231),
        COALESCE(TO_CHAR(s.d_scr,'YYYYMMDD')::INT, 99991231), COALESCE(TO_CHAR(s.d_dec,'YYYYMMDD')::INT, 99991231),
        COALESCE(TO_CHAR(s.d_sig,'YYYYMMDD')::INT, 99991231), COALESCE(TO_CHAR(s.d_dis,'YYYYMMDD')::INT, 99991231),
        COALESCE(TO_CHAR(s.d_wdr,'YYYYMMDD')::INT, 99991231), s.req_amt, s.apr_amt, s.dis_amt, s.score,
        s.d_doc - s.d_sub, s.d_scr - s.d_doc, s.d_dec - s.d_scr, s.d_sig - s.d_dec, s.d_dis - s.d_sig,
        s.d_dis - s.d_dec, s.d_dis - s.d_sub, s.last_ts);
    GET DIAGNOSTICS v_rows = ROW_COUNT;

    UPDATE etl_watermark SET last_loaded_at = p_run_ts WHERE job = 'loan_snapshot';
    RETURN v_rows;
END $$;

-- ---------- Test data: 11 applications ----------
-- loaded_at = the night after the event (nightly file at 01:00)
INSERT INTO src_loan_event (application_no, stage, event_ts, employee_code, client_no, branch_code,
                            product_code, amount_uzs, credit_score, loaded_at)
SELECT v.app, v.stage, v.d::TIMESTAMP + TIME '10:00', v.emp,
       CASE WHEN v.stage = 'submitted' THEN v.cli END,
       CASE WHEN v.stage = 'submitted' THEN v.br  END,
       CASE WHEN v.stage = 'submitted' THEN v.pr  END,
       v.amt, CASE WHEN v.stage = 'scored' THEN 700 END,
       (v.d + 1)::TIMESTAMP + TIME '01:00'
FROM (VALUES
 ('L1','submitted','2026-07-01'::DATE,'E-01',88213,'B-001','CONS',20000000),
 ('L1','docs_verified','2026-07-02','E-01',NULL,NULL,NULL,NULL),
 ('L1','scored','2026-07-03','E-02',NULL,NULL,NULL,NULL),
 ('L1','approved','2026-07-04','E-02',NULL,NULL,NULL,18000000),
 ('L1','signed','2026-07-06','E-01',NULL,NULL,NULL,NULL),
 ('L1','disbursed','2026-07-08','E-03',NULL,NULL,NULL,18000000),
 ('L2','submitted','2026-07-10','E-01',93110,'B-001','CONS',30000000),
 ('L2','docs_verified','2026-07-12','E-01',NULL,NULL,NULL,NULL),
 ('L2','scored','2026-07-13','E-02',NULL,NULL,NULL,NULL),
 ('L2','approved','2026-07-15','E-02',NULL,NULL,NULL,30000000),
 ('L2','signed','2026-07-20','E-01',NULL,NULL,NULL,NULL),
 ('L2','disbursed','2026-07-25','E-03',NULL,NULL,NULL,30000000),
 ('L3','submitted','2026-08-01','E-01',88213,'B-001','MORT',400000000),
 ('L3','docs_verified','2026-08-10','E-01',NULL,NULL,NULL,NULL),
 ('L3','scored','2026-08-12','E-02',NULL,NULL,NULL,NULL),
 ('L3','approved','2026-08-20','E-02',NULL,NULL,NULL,380000000),
 ('L3','signed','2026-08-25','E-01',NULL,NULL,NULL,NULL),
 ('L3','disbursed','2026-09-05','E-03',NULL,NULL,NULL,380000000),
 ('L4','submitted','2026-07-05','E-01',91002,'B-010','CONS',10000000),
 ('L4','docs_verified','2026-07-06','E-01',NULL,NULL,NULL,NULL),
 ('L4','scored','2026-07-07','E-02',NULL,NULL,NULL,NULL),
 ('L4','approved','2026-07-08','E-02',NULL,NULL,NULL,10000000),
 ('L4','signed','2026-07-09','E-01',NULL,NULL,NULL,NULL),
 ('L4','disbursed','2026-07-10','E-03',NULL,NULL,NULL,10000000),
 ('L5','submitted','2026-08-03','E-01',91002,'B-010','AUTO',90000000),
 ('L5','docs_verified','2026-08-05','E-01',NULL,NULL,NULL,NULL),
 ('L5','scored','2026-08-06','E-02',NULL,NULL,NULL,NULL),
 ('L5','approved','2026-08-09','E-02',NULL,NULL,NULL,85000000),
 ('L5','signed','2026-08-12','E-01',NULL,NULL,NULL,NULL),
 ('L5','disbursed','2026-08-20','E-03',NULL,NULL,NULL,85000000),
 ('L6','submitted','2026-08-15','E-01',91002,'B-010','MORT',500000000),
 ('L6','docs_verified','2026-08-30','E-01',NULL,NULL,NULL,NULL),
 ('L6','scored','2026-09-02','E-02',NULL,NULL,NULL,NULL),
 ('L6','approved','2026-09-10','E-02',NULL,NULL,NULL,450000000),
 ('L6','signed','2026-09-15','E-01',NULL,NULL,NULL,NULL),
 ('L6','disbursed','2026-09-30','E-03',NULL,NULL,NULL,450000000),
 ('L7','submitted','2026-07-02','E-01',93110,'B-002','CONS',15000000),
 ('L7','docs_verified','2026-07-03','E-01',NULL,NULL,NULL,NULL),
 ('L7','scored','2026-07-04','E-02',NULL,NULL,NULL,NULL),
 ('L7','rejected','2026-07-05','E-02',NULL,NULL,NULL,NULL),
 ('L8','submitted','2026-08-07','E-01',93110,'B-002','AUTO',60000000),
 ('L8','docs_verified','2026-08-08','E-01',NULL,NULL,NULL,NULL),
 ('L8','withdrawn','2026-08-12','E-01',NULL,NULL,NULL,NULL),
 ('L9','submitted','2026-09-01','E-01',88213,'B-002','CONS',12000000),
 ('L10','submitted','2026-09-05','E-01',93110,'B-002','MORT',300000000),
 ('L10','docs_verified','2026-09-08','E-01',NULL,NULL,NULL,NULL),
 ('L10','scored','2026-09-10','E-02',NULL,NULL,NULL,NULL),
 ('L10','approved','2026-09-12','E-02',NULL,NULL,NULL,280000000),
 ('L11','submitted','2026-09-20','E-01',88213,'B-001','CONS',25000000),
 ('L11','docs_verified','2026-09-21','E-01',NULL,NULL,NULL,NULL),
 ('L11','scored','2026-09-22','E-02',NULL,NULL,NULL,NULL),
 ('L11','approved','2026-09-23','E-02',NULL,NULL,NULL,25000000),
 ('L11','signed','2026-09-28','E-01',NULL,NULL,NULL,NULL),
 ('L11','disbursed','2026-10-05','E-03',NULL,NULL,NULL,25000000)
) AS v(app, stage, d, emp, cli, br, pr, amt);
