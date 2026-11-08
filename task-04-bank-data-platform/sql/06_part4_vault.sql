-- Part 4: Raw Data Vault for the customer (all identifiers below are invented)
DROP SCHEMA IF EXISTS vault CASCADE;
CREATE SCHEMA vault;
SET search_path TO vault;

-- ---------- Hubs ----------
-- Business key = PINFL (national personal ID). The only identifier that all
-- five systems can be mapped to, it never changes, it is unique per person.
CREATE TABLE hub_customer (
    customer_hk   CHAR(32) PRIMARY KEY,           -- md5(upper(trim(pinfl)))
    pinfl         CHAR(14) NOT NULL UNIQUE,       -- RESTRICTED zone only
    load_date     TIMESTAMP NOT NULL,
    record_source TEXT NOT NULL
);

-- Source identifiers: client_no / card_holder_id / app_user_id / crm_id
CREATE TABLE hub_source_customer (
    src_customer_hk    CHAR(32) PRIMARY KEY,      -- md5(system || '|' || id)
    source_system      TEXT NOT NULL,             -- ABS / CARD / APP / CRM
    source_customer_id TEXT NOT NULL,
    load_date          TIMESTAMP NOT NULL,
    record_source      TEXT NOT NULL,
    UNIQUE (source_system, source_customer_id)
);

CREATE TABLE hub_account (
    account_hk    CHAR(32) PRIMARY KEY,
    account_no    TEXT NOT NULL UNIQUE,
    load_date     TIMESTAMP NOT NULL,
    record_source TEXT NOT NULL
);

-- ---------- Links ----------
-- Same-as link: filled from the KYC system, which knows PINFL and every source ID
CREATE TABLE link_customer_identity (
    link_hk         CHAR(32) PRIMARY KEY,         -- md5(customer_hk || src_customer_hk)
    customer_hk     CHAR(32) NOT NULL REFERENCES hub_customer,
    src_customer_hk CHAR(32) NOT NULL REFERENCES hub_source_customer,
    load_date       TIMESTAMP NOT NULL,
    record_source   TEXT NOT NULL,
    UNIQUE (customer_hk, src_customer_hk)
);

CREATE TABLE link_customer_account (
    link_hk         CHAR(32) PRIMARY KEY,
    src_customer_hk CHAR(32) NOT NULL REFERENCES hub_source_customer,
    account_hk      CHAR(32) NOT NULL REFERENCES hub_account,
    load_date       TIMESTAMP NOT NULL,
    record_source   TEXT NOT NULL,
    UNIQUE (src_customer_hk, account_hk)
);

-- ---------- Satellites (insert-only; one row per CHANGE) ----------
CREATE TABLE sat_kyc_customer (                   -- on hub_customer, RESTRICTED
    customer_hk   CHAR(32) NOT NULL REFERENCES hub_customer,
    load_date     TIMESTAMP NOT NULL,
    hash_diff     CHAR(32) NOT NULL,
    record_source TEXT NOT NULL,
    full_name     TEXT, passport_no TEXT, risk_rating TEXT, sanctions_flag BOOLEAN,
    PRIMARY KEY (customer_hk, load_date)
);
CREATE TABLE sat_abs_customer (                   -- core banking
    src_customer_hk CHAR(32) NOT NULL REFERENCES hub_source_customer,
    load_date     TIMESTAMP NOT NULL,
    hash_diff     CHAR(32) NOT NULL,
    record_source TEXT NOT NULL,
    branch_code   TEXT, client_status TEXT,
    PRIMARY KEY (src_customer_hk, load_date)
);
CREATE TABLE sat_card_customer (                  -- card processing
    src_customer_hk CHAR(32) NOT NULL REFERENCES hub_source_customer,
    load_date     TIMESTAMP NOT NULL,
    hash_diff     CHAR(32) NOT NULL,
    record_source TEXT NOT NULL,
    source_changed_at TIMESTAMP,
    address       TEXT,
    PRIMARY KEY (src_customer_hk, load_date)
);
CREATE TABLE sat_app_customer (                   -- mobile app
    src_customer_hk CHAR(32) NOT NULL REFERENCES hub_source_customer,
    load_date     TIMESTAMP NOT NULL,
    hash_diff     CHAR(32) NOT NULL,
    record_source TEXT NOT NULL,
    phone         TEXT, device_id TEXT,
    PRIMARY KEY (src_customer_hk, load_date)
);
CREATE TABLE sat_crm_customer (                   -- CRM
    src_customer_hk CHAR(32) NOT NULL REFERENCES hub_source_customer,
    load_date     TIMESTAMP NOT NULL,             -- when WE loaded it
    hash_diff     CHAR(32) NOT NULL,
    record_source TEXT NOT NULL,
    source_changed_at TIMESTAMP,                  -- when the SOURCE changed it
    segment       TEXT, address TEXT, relationship_manager TEXT,
    PRIMARY KEY (src_customer_hk, load_date)
);

-- ---------- Sample load ----------
INSERT INTO hub_customer VALUES (md5('12345678901234'), '12345678901234', '2025-11-10 02:00', 'KYC');
INSERT INTO hub_source_customer
SELECT md5(s || '|' || i), s, i, '2025-11-10 02:00', s
FROM (VALUES ('ABS','88213'),('CARD','5519'),('APP','7c1e-demo'),('CRM','C-2290')) v(s,i);
INSERT INTO link_customer_identity
SELECT md5(md5('12345678901234') || h.src_customer_hk), md5('12345678901234'), h.src_customer_hk,
       '2025-11-10 02:00', 'KYC'
FROM hub_source_customer h;

INSERT INTO sat_kyc_customer VALUES
 (md5('12345678901234'), '2025-11-10 02:00', md5('Aziz T.|AA0000000|low|f'), 'KYC', 'Aziz T.', 'AA0000000', 'low', FALSE);
INSERT INTO sat_abs_customer VALUES
 (md5('ABS|88213'), '2025-11-10 02:00', md5('B-001|active'), 'ABS', 'B-001', 'active');
INSERT INTO sat_app_customer VALUES
 (md5('APP|7c1e-demo'), '2025-11-10 02:00', md5('+998901112233|dev-1'), 'APP', '+998901112233', 'dev-1');

-- Generic insert-only loader for CRM / CARD: add a row only if hash_diff changed
CREATE OR REPLACE FUNCTION load_crm(p_id TEXT, p_load TIMESTAMP, p_changed TIMESTAMP,
                                    p_segment TEXT, p_address TEXT, p_rm TEXT) RETURNS INTEGER
LANGUAGE plpgsql AS $$
DECLARE hk CHAR(32) := md5('CRM|' || p_id); hd CHAR(32) := md5(p_segment||'|'||p_address||'|'||p_rm); n INT;
BEGIN
    INSERT INTO sat_crm_customer (src_customer_hk, load_date, hash_diff, record_source, source_changed_at,
                                  segment, address, relationship_manager)
    SELECT hk, p_load, hd, 'CRM', p_changed, p_segment, p_address, p_rm
    WHERE hd IS DISTINCT FROM (SELECT hash_diff FROM sat_crm_customer WHERE src_customer_hk = hk
                                ORDER BY load_date DESC LIMIT 1);
    GET DIAGNOSTICS n = ROW_COUNT; RETURN n;
END $$;

CREATE OR REPLACE FUNCTION load_card(p_id TEXT, p_load TIMESTAMP, p_changed TIMESTAMP, p_address TEXT) RETURNS INTEGER
LANGUAGE plpgsql AS $$
DECLARE hk CHAR(32) := md5('CARD|' || p_id); hd CHAR(32) := md5(p_address); n INT;
BEGIN
    INSERT INTO sat_card_customer (src_customer_hk, load_date, hash_diff, record_source, source_changed_at, address)
    SELECT hk, p_load, hd, 'CARD', p_changed, p_address
    WHERE hd IS DISTINCT FROM (SELECT hash_diff FROM sat_card_customer WHERE src_customer_hk = hk
                                ORDER BY load_date DESC LIMIT 1);
    GET DIAGNOSTICS n = ROW_COUNT; RETURN n;
END $$;

SELECT load_crm ('C-2290','2025-11-11 02:00','2025-11-10 09:00','mass',     'Chilonzor 5, Tashkent', 'RM-7');
SELECT load_card('5519',   '2025-11-10 02:00','2025-11-10 09:00',            'Chilonzor 5, Tashkent');
-- 2026-02-08 the CRM segment changes, but the file arrives late (loaded 02-12)
SELECT load_crm ('C-2290','2026-02-12 02:00','2026-02-08 14:00','affluent', 'Chilonzor 5, Tashkent', 'RM-7');
-- 2026-05-03 the card system receives a new address; the CRM still sends the old one
SELECT load_card('5519',   '2026-05-03 02:00','2026-05-03 11:00',            'Yunusobod 12, Tashkent');
SELECT load_crm ('C-2290','2026-05-04 02:00','2026-02-08 14:00','affluent', 'Chilonzor 5, Tashkent', 'RM-7');  -- no change -> 0 rows
