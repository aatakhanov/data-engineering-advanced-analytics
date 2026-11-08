-- lab3.sql : every statement of Exercise Pack 3 (Water Utility), in the order it was run.
-- Database: suvta (PostgreSQL 18).   Order: Part 1, Task 1.10 (needs -v op_pw=<password>), Part 2.
-- Task 1.10 test script (run while connected as district_operator) is at the end of Part 1.


-- ======================================================================
-- PART 1: Tasks 1.1 - 1.9
-- ======================================================================
-- ===================== Part 1: Implementation (database: suvta) =====================
\timing on

-- ---------- Task 1.1: core schema ----------
CREATE TYPE customer_type AS ENUM ('household', 'business', 'government');

CREATE TABLE region (
    region_id INT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    name      TEXT NOT NULL UNIQUE
);

CREATE TABLE district (
    district_id INT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    region_id   INT NOT NULL REFERENCES region (region_id),
    name        TEXT NOT NULL,
    UNIQUE (region_id, name)                     -- unique within a region
);

CREATE TABLE customer (
    account_no    VARCHAR(12) PRIMARY KEY,
    full_name     TEXT NOT NULL,
    district_id   INT  NOT NULL REFERENCES district (district_id),
    address       TEXT NOT NULL,
    customer_type customer_type NOT NULL,
    connected_on  DATE DEFAULT CURRENT_DATE
);

CREATE TABLE water_meter (
    meter_id    INT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    account_no  VARCHAR(12) NOT NULL REFERENCES customer (account_no),
    serial_no   TEXT NOT NULL UNIQUE,
    installed_on DATE NOT NULL,
    diameter_mm INT NOT NULL CHECK (diameter_mm IN (15, 20, 25, 32, 40, 50))
);

CREATE TABLE meter_reading (
    reading_id   BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    meter_id     INT NOT NULL REFERENCES water_meter (meter_id),
    reading_date DATE NOT NULL,
    value_m3     NUMERIC(12,2) NOT NULL CHECK (value_m3 >= 0),
    UNIQUE (meter_id, reading_date)              -- one reading per meter per date
);

CREATE TABLE pumping_station (
    station_id   INT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    district_id  INT NOT NULL REFERENCES district (district_id),
    name         TEXT NOT NULL UNIQUE,
    capacity_m3h NUMERIC NOT NULL CHECK (capacity_m3h > 0)
);

CREATE TABLE telemetry (                         -- raw sensor feed, no primary key
    station_id   INT NOT NULL REFERENCES pumping_station (station_id),
    ts           TIMESTAMPTZ NOT NULL,
    pressure_bar NUMERIC(4,2) CHECK (pressure_bar >= 0),
    flow_m3h     NUMERIC(8,2) CHECK (flow_m3h >= 0)
);

-- ---------- Task 1.2: sample data ----------
INSERT INTO region (name) VALUES ('Toshkent viloyati'), ('Samarqand viloyati');
INSERT INTO district (region_id, name) VALUES (1,'Chirchiq'), (1,'Olmaliq'), (2,'Urgut');
INSERT INTO customer (account_no, full_name, district_id, address, customer_type, connected_on) VALUES
 ('TV-0000001','Aliyev Anvar',1,'Navoiy ko''chasi 12','household','2020-05-01'),
 ('TV-0000002','Chirchiq Non MChJ',1,'Amir Temur ko''chasi 3','business','2019-03-15'),
 ('TV-0000003','Olmaliq 5-maktab',2,'Mustaqillik ko''chasi 40','government','2018-09-01'),
 ('SM-0000001','Karimova Dilfuza',3,'Navoiy ko''chasi 7','household','2021-02-10');
INSERT INTO water_meter (account_no, serial_no, installed_on, diameter_mm) VALUES
 ('TV-0000001','WM-1001','2023-01-10',15), ('TV-0000002','WM-1002','2022-06-01',25),
 ('TV-0000003','WM-1003','2022-09-01',32), ('SM-0000001','WM-2001','2024-01-05',15);
INSERT INTO meter_reading (meter_id, reading_date, value_m3) VALUES
 (1,'2026-07-01',120.00),  (1,'2026-08-01',132.50),  (1,'2026-09-01',145.10),  (1,'2026-10-01',156.80),
 (2,'2026-07-01',3400.00), (2,'2026-08-01',3655.00), (2,'2026-09-01',3901.00), (2,'2026-10-01',4180.00),
 (3,'2026-07-01',980.00),  (3,'2026-08-01',1110.00), (3,'2026-09-01',1205.00), (3,'2026-10-01',1340.00),
 (4,'2026-07-01',45.00),   (4,'2026-08-01',53.20),   (4,'2026-09-01',61.70),   (4,'2026-10-01',69.90);
INSERT INTO pumping_station (district_id, name, capacity_m3h) VALUES
 (1,'Chirchiq NS-1',1200), (2,'Olmaliq NS-2',800), (3,'Urgut NS-1',600);

-- ---------- Task 1.3: readings can only go up ----------
CREATE FUNCTION check_reading_increasing() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE prev_val NUMERIC; next_val NUMERIC;
BEGIN
    SELECT value_m3 INTO prev_val FROM meter_reading
     WHERE meter_id = NEW.meter_id AND reading_date < NEW.reading_date
       AND reading_id IS DISTINCT FROM NEW.reading_id
     ORDER BY reading_date DESC LIMIT 1;
    IF prev_val IS NOT NULL AND NEW.value_m3 < prev_val THEN
        RAISE EXCEPTION 'Meter % reading % on % is lower than the previous reading %',
            NEW.meter_id, NEW.value_m3, NEW.reading_date, prev_val;
    END IF;
    -- an earlier reading must also not be higher than a later one (matters on UPDATE / back-dated INSERT)
    SELECT value_m3 INTO next_val FROM meter_reading
     WHERE meter_id = NEW.meter_id AND reading_date > NEW.reading_date
       AND reading_id IS DISTINCT FROM NEW.reading_id
     ORDER BY reading_date LIMIT 1;
    IF next_val IS NOT NULL AND NEW.value_m3 > next_val THEN
        RAISE EXCEPTION 'Meter % reading % on % is higher than the next reading %',
            NEW.meter_id, NEW.value_m3, NEW.reading_date, next_val;
    END IF;
    RETURN NEW;
END $$;

CREATE TRIGGER trg_reading_increasing
BEFORE INSERT OR UPDATE ON meter_reading
FOR EACH ROW EXECUTE FUNCTION check_reading_increasing();

\echo '--- 1.3 test: 150.00 must FAIL'
INSERT INTO meter_reading (meter_id, reading_date, value_m3) VALUES (1, '2026-11-01', 150.00);
\echo '--- 1.3 test: 168.40 must SUCCEED'
INSERT INTO meter_reading (meter_id, reading_date, value_m3) VALUES (1, '2026-11-01', 168.40);

-- ---------- Task 1.4: monthly consumption view ----------
-- month = month of the CURRENT reading (the reading on 2026-10-01 gives "October" consumption, as in Task 2.9)
CREATE VIEW monthly_consumption AS
SELECT account_no, meter_id, month, consumption_m3
FROM (
    SELECT m.account_no, r.meter_id,
           date_trunc('month', r.reading_date)::date AS month,
           r.value_m3 - LAG(r.value_m3) OVER (PARTITION BY r.meter_id ORDER BY r.reading_date) AS consumption_m3
    FROM meter_reading r JOIN water_meter m USING (meter_id)
) x
WHERE consumption_m3 IS NOT NULL;               -- first reading of each meter has no consumption

\echo '--- 1.4 view for meter 1'
SELECT * FROM monthly_consumption WHERE meter_id = 1 ORDER BY month;

-- ---------- Task 1.5: tariffs with validity periods ----------
CREATE EXTENSION IF NOT EXISTS btree_gist;
CREATE TABLE tariff (
    tariff_id     INT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    customer_type customer_type NOT NULL,
    price_per_m3  NUMERIC(12,2) NOT NULL CHECK (price_per_m3 > 0),
    valid_from    DATE NOT NULL,
    valid_to      DATE,                          -- NULL = still valid
    CHECK (valid_to IS NULL OR valid_to >= valid_from),
    EXCLUDE USING gist (customer_type WITH =, daterange(valid_from, valid_to, '[]') WITH &&)
);
INSERT INTO tariff (customer_type, price_per_m3, valid_from, valid_to) VALUES
 ('household', 2500, '2024-01-01', '2026-06-30'), ('household', 3000, '2026-07-01', NULL),
 ('business',  6000, '2024-01-01', '2026-06-30'), ('business',  7000, '2026-07-01', NULL),
 ('government',5000, '2024-01-01', '2026-06-30'), ('government',5500, '2026-07-01', NULL);

CREATE FUNCTION tariff_for(p_type customer_type, p_date DATE) RETURNS NUMERIC
LANGUAGE sql STABLE AS $$
    SELECT price_per_m3 FROM tariff
     WHERE customer_type = p_type AND p_date >= valid_from
       AND (valid_to IS NULL OR p_date <= valid_to);
$$;

\echo '--- 1.5 tariff_for checks: 2500, 3000, 7000'
SELECT tariff_for('household','2026-06-30') AS hh_june, tariff_for('household','2026-07-01') AS hh_july,
       tariff_for('business','2026-09-15') AS biz_sept;
\echo '--- 1.5 overlapping household tariff from 2026-09-01 must be REFUSED'
INSERT INTO tariff (customer_type, price_per_m3, valid_from) VALUES ('household', 3200, '2026-09-01');

-- ---------- Task 1.6: monthly billing ----------
CREATE TYPE invoice_status AS ENUM ('unpaid', 'paid', 'overdue');
CREATE TABLE invoice (
    invoice_id INT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    account_no VARCHAR(12) NOT NULL REFERENCES customer (account_no),
    period     DATE NOT NULL CHECK (period = date_trunc('month', period)::date),   -- first day of month
    volume_m3  NUMERIC(12,2) NOT NULL,
    amount     NUMERIC(14,2) NOT NULL,
    status     invoice_status NOT NULL DEFAULT 'unpaid',
    issued_on  DATE NOT NULL DEFAULT CURRENT_DATE,
    UNIQUE (account_no, period)                  -- one invoice per account per period
);

CREATE PROCEDURE generate_invoices(p_period DATE) LANGUAGE sql AS $$
    INSERT INTO invoice (account_no, period, volume_m3, amount)
    SELECT c.account_no, p_period,
           SUM(r2.value_m3 - r1.value_m3),
           ROUND(SUM(r2.value_m3 - r1.value_m3) * tariff_for(c.customer_type, p_period), 2)
    FROM customer c
    JOIN water_meter m ON m.account_no = c.account_no
    JOIN meter_reading r1 ON r1.meter_id = m.meter_id AND r1.reading_date = p_period
    JOIN meter_reading r2 ON r2.meter_id = m.meter_id
                         AND r2.reading_date = (p_period + INTERVAL '1 month')::date
    GROUP BY c.account_no, c.customer_type
    ON CONFLICT (account_no, period) DO NOTHING;   -- running twice creates no duplicates
$$;

CALL generate_invoices('2026-07-01');
CALL generate_invoices('2026-08-01');
CALL generate_invoices('2026-09-01');
\echo '--- 1.6 run July again: no duplicates'
CALL generate_invoices('2026-07-01');
SELECT account_no, period, volume_m3, amount, status FROM invoice ORDER BY period, account_no;
SELECT COUNT(*) AS invoices, COUNT(DISTINCT (account_no, period)) AS distinct_pairs FROM invoice;

-- ---------- Task 1.7: payments ----------
CREATE TABLE payment (
    payment_id INT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    invoice_id INT NOT NULL REFERENCES invoice (invoice_id),
    amount     NUMERIC(14,2) NOT NULL CHECK (amount > 0),
    paid_at    TIMESTAMPTZ NOT NULL DEFAULT now(),
    channel    TEXT NOT NULL CHECK (channel IN ('Payme', 'Click', 'bank', 'cash'))
);

CREATE FUNCTION mark_invoice_paid() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
    UPDATE invoice i SET status = 'paid'
     WHERE i.invoice_id = NEW.invoice_id AND i.status <> 'paid'
       AND (SELECT SUM(p.amount) FROM payment p WHERE p.invoice_id = i.invoice_id) >= i.amount;
    RETURN NULL;
END $$;
CREATE TRIGGER trg_payment_marks_paid AFTER INSERT ON payment
FOR EACH ROW EXECUTE FUNCTION mark_invoice_paid();

\echo '--- 1.7 Aliyev Anvar September invoice, two payments'
SELECT invoice_id, amount, status FROM invoice WHERE account_no = 'TV-0000001' AND period = '2026-09-01';
INSERT INTO payment (invoice_id, amount, channel)
SELECT invoice_id, 20000, 'Payme' FROM invoice WHERE account_no = 'TV-0000001' AND period = '2026-09-01';
\echo '    after the FIRST payment: still unpaid'
SELECT invoice_id, amount, status FROM invoice WHERE account_no = 'TV-0000001' AND period = '2026-09-01';
INSERT INTO payment (invoice_id, amount, channel)
SELECT invoice_id, amount - 20000, 'Click' FROM invoice WHERE account_no = 'TV-0000001' AND period = '2026-09-01';
\echo '    after the SECOND payment: paid'
SELECT invoice_id, amount, status FROM invoice WHERE account_no = 'TV-0000001' AND period = '2026-09-01';

-- Invoices are issued early in the following month (as in the Task 2.1 script)
UPDATE invoice SET issued_on = (period + INTERVAL '1 month 2 days')::date;
\echo '--- 1.7 mark unpaid invoices issued more than 30 days ago as overdue'
UPDATE invoice SET status = 'overdue' WHERE status = 'unpaid' AND issued_on < CURRENT_DATE - 30;
SELECT account_no, period, issued_on, status FROM invoice ORDER BY period, account_no;

-- ---------- Task 1.8: incidents ----------
CREATE TABLE incident (
    incident_id   INT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    district_id   INT NOT NULL REFERENCES district (district_id),
    station_id    INT REFERENCES pumping_station (station_id),
    incident_type TEXT NOT NULL CHECK (incident_type IN ('leak', 'burst_pipe', 'low_pressure', 'no_water')),
    reported_at   TIMESTAMPTZ NOT NULL,
    resolved_at   TIMESTAMPTZ,
    CHECK (resolved_at IS NULL OR resolved_at > reported_at)
);
INSERT INTO incident (district_id, station_id, incident_type, reported_at, resolved_at) VALUES
 (1, 1,    'leak',         '2026-09-03 08:10+05', '2026-09-03 14:40+05'),
 (1, 1,    'low_pressure', '2026-10-12 06:00+05', '2026-10-12 09:30+05'),
 (1, NULL, 'burst_pipe',   '2026-10-28 17:45+05', NULL),
 (2, 2,    'no_water',     '2026-08-20 05:30+05', '2026-08-20 13:00+05'),
 (2, NULL, 'leak',         '2026-10-30 11:15+05', NULL),
 (3, 3,    'burst_pipe',   '2026-07-15 21:00+05', '2026-07-16 10:00+05'),
 (3, 3,    'low_pressure', '2026-09-22 07:20+05', '2026-09-22 12:20+05');

\echo '--- 1.8 incidents by district'
SELECT d.name AS district,
       COUNT(i.incident_id) FILTER (WHERE i.resolved_at IS NULL)     AS open_incidents,
       COUNT(i.incident_id) FILTER (WHERE i.resolved_at IS NOT NULL) AS resolved_incidents,
       ROUND(AVG(EXTRACT(EPOCH FROM (i.resolved_at - i.reported_at)) / 3600)::numeric, 1) AS avg_repair_hours
FROM district d LEFT JOIN incident i USING (district_id)
GROUP BY d.district_id, d.name ORDER BY d.district_id;

-- ---------- Task 1.9: water quality ----------
CREATE TABLE quality_sample (
    sample_id      INT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    station_id     INT NOT NULL REFERENCES pumping_station (station_id),
    taken_at       TIMESTAMPTZ NOT NULL,
    chlorine_mg_l  NUMERIC(4,2) NOT NULL CHECK (chlorine_mg_l >= 0),
    turbidity_ntu  NUMERIC(5,2) NOT NULL CHECK (turbidity_ntu >= 0)
);
INSERT INTO quality_sample (station_id, taken_at, chlorine_mg_l, turbidity_ntu) VALUES
 (1, '2026-10-01 09:00+05', 0.40, 0.8),
 (1, '2026-10-15 09:00+05', 0.25, 0.9),   -- chlorine too low
 (2, '2026-10-02 10:00+05', 0.45, 1.0),
 (2, '2026-10-16 10:00+05', 0.35, 2.1),   -- turbidity too high
 (3, '2026-10-03 11:00+05', 0.30, 1.2),
 (3, '2026-10-17 11:00+05', 0.55, 1.8),   -- chlorine too high AND turbidity too high
 (1, '2026-10-29 09:00+05', 0.42, 0.7),
 (3, '2026-10-30 11:00+05', 0.38, 1.4);

CREATE VIEW quality_alerts AS
SELECT s.sample_id, s.station_id, s.taken_at, s.chlorine_mg_l, s.turbidity_ntu,
       concat_ws('; ',
           CASE WHEN s.chlorine_mg_l < 0.3 THEN 'chlorine below 0.3 mg/L' END,
           CASE WHEN s.chlorine_mg_l > 0.5 THEN 'chlorine above 0.5 mg/L' END,
           CASE WHEN s.turbidity_ntu > 1.5 THEN 'turbidity above 1.5 NTU' END) AS limit_broken
FROM quality_sample s
WHERE s.chlorine_mg_l NOT BETWEEN 0.3 AND 0.5 OR s.turbidity_ntu > 1.5;

\echo '--- 1.9 quality alerts'
SELECT * FROM quality_alerts ORDER BY sample_id;


-- ======================================================================
-- PART 1: Task 1.10 (create role and policies)
-- ======================================================================
-- ---------- Task 1.10: row-level security for district operators ----------
-- Run as the database owner. The password comes from the command line:
--   psql -v op_pw=... -f p1_rls.sql      (it is not stored in this file)
CREATE ROLE district_operator LOGIN PASSWORD :'op_pw';

GRANT USAGE ON SCHEMA public TO district_operator;
GRANT SELECT ON customer, water_meter, meter_reading TO district_operator;
GRANT INSERT ON meter_reading TO district_operator;

ALTER TABLE customer      ENABLE ROW LEVEL SECURITY;
ALTER TABLE water_meter   ENABLE ROW LEVEL SECURITY;
ALTER TABLE meter_reading ENABLE ROW LEVEL SECURITY;

-- the operator's district is passed in the session: SET app.district_id = '1';
CREATE POLICY operator_customer ON customer FOR SELECT TO district_operator
    USING (district_id = NULLIF(current_setting('app.district_id', true), '')::int);

CREATE POLICY operator_meter ON water_meter FOR SELECT TO district_operator
    USING (EXISTS (SELECT 1 FROM customer c
                    WHERE c.account_no = water_meter.account_no
                      AND c.district_id = NULLIF(current_setting('app.district_id', true), '')::int));

CREATE POLICY operator_reading_select ON meter_reading FOR SELECT TO district_operator
    USING (EXISTS (SELECT 1 FROM water_meter m JOIN customer c USING (account_no)
                    WHERE m.meter_id = meter_reading.meter_id
                      AND c.district_id = NULLIF(current_setting('app.district_id', true), '')::int));

CREATE POLICY operator_reading_insert ON meter_reading FOR INSERT TO district_operator
    WITH CHECK (EXISTS (SELECT 1 FROM water_meter m JOIN customer c USING (account_no)
                         WHERE m.meter_id = meter_reading.meter_id
                           AND c.district_id = NULLIF(current_setting('app.district_id', true), '')::int));


-- ======================================================================
-- PART 1: Task 1.10 (test, run as district_operator)
-- ======================================================================
-- Task 1.10 test, run while connected AS district_operator
SELECT current_user;
SET app.district_id = '1';
\echo '--- customers visible to district 1 (Chirchiq): expect TV-0000001, TV-0000002'
SELECT account_no, full_name, district_id FROM customer ORDER BY account_no;
\echo '--- meters visible: expect meters 1 and 2'
SELECT meter_id, account_no FROM water_meter ORDER BY meter_id;
\echo '--- readings visible: only meters 1 and 2 (counts per meter)'
SELECT meter_id, COUNT(*) FROM meter_reading GROUP BY meter_id ORDER BY meter_id;
\echo '--- insert a reading for the URGUT meter (meter 4): must be REFUSED'
INSERT INTO meter_reading (meter_id, reading_date, value_m3) VALUES (4, '2026-11-01', 80.00);
\echo '--- insert a reading for a Chirchiq meter (meter 2): allowed (rolled back)'
BEGIN;
INSERT INTO meter_reading (meter_id, reading_date, value_m3) VALUES (2, '2026-11-01', 4400.00);
SELECT meter_id, reading_date, value_m3 FROM meter_reading WHERE meter_id = 2 AND reading_date = '2026-11-01';
ROLLBACK;
\echo '--- without app.district_id nothing is visible'
RESET app.district_id;
SELECT COUNT(*) AS visible_customers FROM customer;


-- ======================================================================
-- PART 2: Task 2.1 (generate the data)
-- ======================================================================
-- ===================== Part 2: Optimization =====================
\timing on
-- ---------- Task 2.1: generate the data ----------
ALTER TABLE meter_reading DISABLE TRIGGER trg_reading_increasing;

-- 20 more districts
INSERT INTO district (region_id, name)
SELECT 1 + (g % 2), 'District ' || g FROM generate_series(1, 20) g;

-- 100,000 customers
INSERT INTO customer (account_no, full_name, district_id, address, customer_type, connected_on)
SELECT 'GN-' || lpad(g::text, 7, '0'),
       'Customer ' || g,
       d.ids[1 + floor(random()*array_length(d.ids,1))::int],
       (ARRAY['Navoiy','Amir Temur','Mustaqillik','Bunyodkor','Yangi hayot'])[1 + floor(random()*5)::int]
         || ' ko''chasi ' || (1 + floor(random()*200)::int),
       (CASE WHEN random() < 0.90 THEN 'household'
             WHEN random() < 0.70 THEN 'business' ELSE 'government' END)::customer_type,
       DATE '2015-01-01' + floor(random()*3000)::int
FROM generate_series(1, 100000) g,
     (SELECT array_agg(district_id) AS ids FROM district) d;

-- one meter per new customer
INSERT INTO water_meter (account_no, serial_no, installed_on, diameter_mm)
SELECT account_no, 'GM-' || substr(account_no, 4),
       DATE '2022-01-01' + floor(random()*365)::int,
       CASE WHEN customer_type = 'household' THEN 15 ELSE 25 END
FROM customer WHERE account_no LIKE 'GN-%';

-- 24 monthly readings per meter (2.4 million rows)
INSERT INTO meter_reading (meter_id, reading_date, value_m3)
SELECT meter_id, d::date,
       round(SUM(use_m3) OVER (PARTITION BY meter_id ORDER BY d)::numeric, 2)
FROM (SELECT m.meter_id, d,
             CASE WHEN m.diameter_mm = 15 THEN 5 + random()*15 ELSE 100 + random()*300 END AS use_m3
      FROM water_meter m
      CROSS JOIN generate_series(DATE '2024-11-01', DATE '2026-10-01', interval '1 month') d
      WHERE m.serial_no LIKE 'GM-%') x;

-- 47 more pumping stations
INSERT INTO pumping_station (district_id, name, capacity_m3h)
SELECT d.ids[1 + floor(random()*array_length(d.ids,1))::int], 'Station ' || g, 300 + floor(random()*1500)
FROM generate_series(1, 47) g,
     (SELECT array_agg(district_id) AS ids FROM district) d;

-- telemetry every 10 minutes for one year (about 2.6 million rows)
INSERT INTO telemetry (station_id, ts, pressure_bar, flow_m3h)
SELECT s.station_id, t,
       round((2.5 + random()*1.5 - CASE WHEN random() < 0.002 THEN 2.2 ELSE 0 END)::numeric, 2),
       round((s.capacity_m3h * (0.4 + random()*0.5))::numeric, 2)
FROM generate_series(TIMESTAMPTZ '2025-11-01 00:00+05', TIMESTAMPTZ '2026-10-31 23:50+05',
                     interval '10 minutes') t
CROSS JOIN pumping_station s
ORDER BY t;

-- invoices for every new account, November 2024 to September 2026
INSERT INTO invoice (account_no, period, volume_m3, amount, status, issued_on)
SELECT c.account_no, r1.reading_date,
       r2.value_m3 - r1.value_m3,
       round((r2.value_m3 - r1.value_m3) * tariff_for(c.customer_type, r1.reading_date), 2),
       (CASE WHEN random() < 0.85 THEN 'paid' ELSE 'unpaid' END)::invoice_status,
       (r1.reading_date + interval '1 month 2 days')::date
FROM customer c
JOIN water_meter m USING (account_no)
JOIN meter_reading r1 ON r1.meter_id = m.meter_id
JOIN meter_reading r2 ON r2.meter_id = m.meter_id
                     AND r2.reading_date = (r1.reading_date + interval '1 month')::date
WHERE c.account_no LIKE 'GN-%';

VACUUM ANALYZE;

ALTER TABLE meter_reading ENABLE TRIGGER trg_reading_increasing;

\echo '--- 2.1 row counts and total sizes'
SELECT 'telemetry' AS tbl, COUNT(*) AS row_count, pg_size_pretty(pg_total_relation_size('telemetry')) AS total_size FROM telemetry
UNION ALL SELECT 'meter_reading', COUNT(*), pg_size_pretty(pg_total_relation_size('meter_reading')) FROM meter_reading
UNION ALL SELECT 'invoice', COUNT(*), pg_size_pretty(pg_total_relation_size('invoice')) FROM invoice;


-- ======================================================================
-- PART 2: Tasks 2.2 - 2.10 (measured with EXPLAIN (ANALYZE, BUFFERS))
-- ======================================================================

-- 2.2 Q1 [before]
EXPLAIN (ANALYZE, BUFFERS) SELECT ts, pressure_bar, flow_m3h FROM telemetry WHERE station_id = 7 AND ts >= '2026-08-15 00:00+05' AND ts < '2026-08-16 00:00+05' ORDER BY ts;

-- 2.2 Q2 [before]
EXPLAIN (ANALYZE, BUFFERS) SELECT station_id, count(*) FROM telemetry WHERE ts >= '2026-10-25 00:00+05' AND pressure_bar < 1.0 GROUP BY station_id;

-- 2.2 Q3 [before]
EXPLAIN (ANALYZE, BUFFERS) SELECT d.name, i.period, SUM(i.volume_m3) AS volume_m3 FROM invoice i JOIN customer c USING (account_no) JOIN district d USING (district_id) WHERE i.period >= '2026-01-01' GROUP BY d.name, i.period;

-- 2.2 Q4 [before]
EXPLAIN (ANALYZE, BUFFERS) SELECT account_no, SUM(amount) AS debt FROM invoice WHERE status <> 'paid' AND issued_on < DATE '2026-10-31' - 60 GROUP BY account_no ORDER BY debt DESC LIMIT 100;

-- 2.2 Q5 [before]
EXPLAIN (ANALYZE, BUFFERS) SELECT account_no, full_name, address FROM customer WHERE address ILIKE '%mustaqillik ko''chasi 17%';

-- 2.2 Q6 [before]
EXPLAIN (ANALYZE, BUFFERS) SELECT r.reading_date, r.value_m3 FROM meter_reading r JOIN water_meter m USING (meter_id) WHERE m.account_no = 'GN-0012345' ORDER BY r.reading_date;

-- 2.3
CREATE INDEX ix_telemetry_station_ts ON telemetry (station_id, ts) INCLUDE (pressure_bar, flow_m3h);

-- 2.3
VACUUM ANALYZE telemetry;

-- 2.3 Q1 [after]
EXPLAIN (ANALYZE, BUFFERS) SELECT ts, pressure_bar, flow_m3h FROM telemetry WHERE station_id = 7 AND ts >= '2026-08-15 00:00+05' AND ts < '2026-08-16 00:00+05' ORDER BY ts;

-- 2.4
CREATE INDEX ix_telemetry_ts_brin ON telemetry USING brin (ts);

-- 2.4 Q2 [BRIN created]
BEGIN;
DROP INDEX ix_telemetry_station_ts;
EXPLAIN (ANALYZE, BUFFERS) SELECT station_id, count(*) FROM telemetry WHERE ts >= '2026-10-25 00:00+05' AND pressure_bar < 1.0 GROUP BY station_id;
ROLLBACK;

-- 2.4
CREATE INDEX ix_telemetry_ts_btree ON telemetry (ts);

-- 2.4 Q2 [BRIN only]
BEGIN;
DROP INDEX ix_telemetry_station_ts;
DROP INDEX ix_telemetry_ts_btree;
EXPLAIN (ANALYZE, BUFFERS) SELECT station_id, count(*) FROM telemetry WHERE ts >= '2026-10-25 00:00+05' AND pressure_bar < 1.0 GROUP BY station_id;
ROLLBACK;

-- 2.4 Q2 [B-tree only]
BEGIN;
DROP INDEX ix_telemetry_station_ts;
DROP INDEX ix_telemetry_ts_brin;
EXPLAIN (ANALYZE, BUFFERS) SELECT station_id, count(*) FROM telemetry WHERE ts >= '2026-10-25 00:00+05' AND pressure_bar < 1.0 GROUP BY station_id;
ROLLBACK;

-- 2.4 Q2 [all indexes present]
EXPLAIN (ANALYZE, BUFFERS) SELECT station_id, count(*) FROM telemetry WHERE ts >= '2026-10-25 00:00+05' AND pressure_bar < 1.0 GROUP BY station_id;

-- 2.4
DROP INDEX ix_telemetry_ts_btree; ANALYZE telemetry;

-- 2.5
CREATE TABLE telemetry_part (
    station_id   INT NOT NULL REFERENCES pumping_station (station_id),
    ts           TIMESTAMPTZ NOT NULL,
    pressure_bar NUMERIC(4,2) CHECK (pressure_bar >= 0),
    flow_m3h     NUMERIC(8,2) CHECK (flow_m3h >= 0)
) PARTITION BY RANGE (ts);
CREATE TABLE telemetry_part_2025_11 PARTITION OF telemetry_part FOR VALUES FROM ('2025-11-01 00:00+05') TO ('2025-12-01 00:00+05');
CREATE TABLE telemetry_part_2025_12 PARTITION OF telemetry_part FOR VALUES FROM ('2025-12-01 00:00+05') TO ('2026-01-01 00:00+05');
CREATE TABLE telemetry_part_2026_01 PARTITION OF telemetry_part FOR VALUES FROM ('2026-01-01 00:00+05') TO ('2026-02-01 00:00+05');
CREATE TABLE telemetry_part_2026_02 PARTITION OF telemetry_part FOR VALUES FROM ('2026-02-01 00:00+05') TO ('2026-03-01 00:00+05');
CREATE TABLE telemetry_part_2026_03 PARTITION OF telemetry_part FOR VALUES FROM ('2026-03-01 00:00+05') TO ('2026-04-01 00:00+05');
CREATE TABLE telemetry_part_2026_04 PARTITION OF telemetry_part FOR VALUES FROM ('2026-04-01 00:00+05') TO ('2026-05-01 00:00+05');
CREATE TABLE telemetry_part_2026_05 PARTITION OF telemetry_part FOR VALUES FROM ('2026-05-01 00:00+05') TO ('2026-06-01 00:00+05');
CREATE TABLE telemetry_part_2026_06 PARTITION OF telemetry_part FOR VALUES FROM ('2026-06-01 00:00+05') TO ('2026-07-01 00:00+05');
CREATE TABLE telemetry_part_2026_07 PARTITION OF telemetry_part FOR VALUES FROM ('2026-07-01 00:00+05') TO ('2026-08-01 00:00+05');
CREATE TABLE telemetry_part_2026_08 PARTITION OF telemetry_part FOR VALUES FROM ('2026-08-01 00:00+05') TO ('2026-09-01 00:00+05');
CREATE TABLE telemetry_part_2026_09 PARTITION OF telemetry_part FOR VALUES FROM ('2026-09-01 00:00+05') TO ('2026-10-01 00:00+05');
CREATE TABLE telemetry_part_2026_10 PARTITION OF telemetry_part FOR VALUES FROM ('2026-10-01 00:00+05') TO ('2026-11-01 00:00+05');

-- 2.5
INSERT INTO telemetry_part SELECT * FROM telemetry;

-- 2.5
CREATE INDEX ix_telemetry_part_station_ts ON telemetry_part (station_id, ts) INCLUDE (pressure_bar, flow_m3h);

-- 2.5
VACUUM ANALYZE telemetry_part;

-- 2.5 Q1 [partitioned]
EXPLAIN (ANALYZE, BUFFERS) SELECT ts, pressure_bar, flow_m3h FROM telemetry_part WHERE station_id = 7 AND ts >= '2026-08-15 00:00+05' AND ts < '2026-08-16 00:00+05' ORDER BY ts;

-- 2.5 Q2 [partitioned]
EXPLAIN (ANALYZE, BUFFERS) SELECT station_id, count(*) FROM telemetry_part WHERE ts >= '2026-10-25 00:00+05' AND pressure_bar < 1.0 GROUP BY station_id;

-- 2.5
BEGIN;
DELETE FROM telemetry WHERE ts < '2025-12-01 00:00+05';
ROLLBACK;

-- 2.5
ALTER TABLE telemetry_part DETACH PARTITION telemetry_part_2025_11;

-- 2.5
DROP TABLE telemetry_part_2025_11;

-- 2.6
CREATE INDEX ix_water_meter_account ON water_meter (account_no); CREATE INDEX ix_customer_district ON customer (district_id); ANALYZE water_meter; ANALYZE customer;

-- 2.6 Q6 [after]
EXPLAIN (ANALYZE, BUFFERS) SELECT r.reading_date, r.value_m3 FROM meter_reading r JOIN water_meter m USING (meter_id) WHERE m.account_no = 'GN-0012345' ORDER BY r.reading_date;

-- 2.6 Q3 [after]
EXPLAIN (ANALYZE, BUFFERS) SELECT d.name, i.period, SUM(i.volume_m3) AS volume_m3 FROM invoice i JOIN customer c USING (account_no) JOIN district d USING (district_id) WHERE i.period >= '2026-01-01' GROUP BY d.name, i.period;

-- 2.7
CREATE INDEX ix_invoice_open ON invoice (issued_on) INCLUDE (account_no, amount) WHERE status <> 'paid'; VACUUM ANALYZE invoice;

-- 2.7
CREATE INDEX ix_invoice_all ON invoice (issued_on) INCLUDE (account_no, amount);

-- 2.7
DROP INDEX ix_invoice_all; ANALYZE invoice;

-- 2.7 Q4 [partial index]
EXPLAIN (ANALYZE, BUFFERS) SELECT account_no, SUM(amount) AS debt FROM invoice WHERE status <> 'paid' AND issued_on < DATE '2026-10-31' - 60 GROUP BY account_no ORDER BY debt DESC LIMIT 100;

-- 2.8
CREATE EXTENSION IF NOT EXISTS pg_trgm;

-- 2.8
CREATE INDEX ix_customer_address_trgm ON customer USING gin (address gin_trgm_ops); ANALYZE customer;

-- 2.8 Q5 [after]
EXPLAIN (ANALYZE, BUFFERS) SELECT account_no, full_name, address FROM customer WHERE address ILIKE '%mustaqillik ko''chasi 17%';

-- 2.9 orig [correlated subquery]
EXPLAIN (ANALYZE, BUFFERS) SELECT r.meter_id, r.reading_date,
       r.value_m3 - (SELECT r2.value_m3 FROM meter_reading r2
                     WHERE r2.meter_id = r.meter_id AND r2.reading_date < r.reading_date
                     ORDER BY r2.reading_date DESC LIMIT 1) AS consumption_m3
FROM meter_reading r
WHERE r.reading_date = DATE '2026-10-01';

-- 2.9 lag [LAG()]
EXPLAIN (ANALYZE, BUFFERS) SELECT meter_id, reading_date, consumption_m3
FROM (SELECT meter_id, reading_date,
             value_m3 - LAG(value_m3) OVER (PARTITION BY meter_id ORDER BY reading_date) AS consumption_m3
      FROM meter_reading
      WHERE reading_date <= DATE '2026-10-01') x
WHERE reading_date = DATE '2026-10-01';

-- 2.9 lagb [LAG() 2 months]
EXPLAIN (ANALYZE, BUFFERS) SELECT meter_id, reading_date, consumption_m3
FROM (SELECT meter_id, reading_date,
             value_m3 - LAG(value_m3) OVER (PARTITION BY meter_id ORDER BY reading_date) AS consumption_m3
      FROM meter_reading
      WHERE reading_date BETWEEN DATE '2026-09-01' AND DATE '2026-10-01') x
WHERE reading_date = DATE '2026-10-01';

-- 2.9 compare
SELECT 'original' AS version, COUNT(*) AS row_count, COUNT(consumption_m3) AS non_null, SUM(consumption_m3) AS sum_m3 FROM (SELECT r.meter_id, r.reading_date,
       r.value_m3 - (SELECT r2.value_m3 FROM meter_reading r2
                     WHERE r2.meter_id = r.meter_id AND r2.reading_date < r.reading_date
                     ORDER BY r2.reading_date DESC LIMIT 1) AS consumption_m3
FROM meter_reading r
WHERE r.reading_date = DATE '2026-10-01') a
UNION ALL SELECT 'LAG', COUNT(*), COUNT(consumption_m3), SUM(consumption_m3) FROM (SELECT meter_id, reading_date, consumption_m3
FROM (SELECT meter_id, reading_date,
             value_m3 - LAG(value_m3) OVER (PARTITION BY meter_id ORDER BY reading_date) AS consumption_m3
      FROM meter_reading
      WHERE reading_date <= DATE '2026-10-01') x
WHERE reading_date = DATE '2026-10-01') b;

-- 2.9 compare (rows only in the original)
SELECT COUNT(*) FROM ((SELECT r.meter_id, r.reading_date,
       r.value_m3 - (SELECT r2.value_m3 FROM meter_reading r2
                     WHERE r2.meter_id = r.meter_id AND r2.reading_date < r.reading_date
                     ORDER BY r2.reading_date DESC LIMIT 1) AS consumption_m3
FROM meter_reading r
WHERE r.reading_date = DATE '2026-10-01') EXCEPT (SELECT meter_id, reading_date, consumption_m3
FROM (SELECT meter_id, reading_date,
             value_m3 - LAG(value_m3) OVER (PARTITION BY meter_id ORDER BY reading_date) AS consumption_m3
      FROM meter_reading
      WHERE reading_date <= DATE '2026-10-01') x
WHERE reading_date = DATE '2026-10-01')) x;

-- 2.10
CREATE MATERIALIZED VIEW district_monthly AS
SELECT d.name AS district_name, i.period, SUM(i.volume_m3) AS volume_m3
FROM invoice i JOIN customer c USING (account_no) JOIN district d USING (district_id)
WHERE i.period >= '2026-01-01'
GROUP BY d.name, i.period;
CREATE UNIQUE INDEX ux_district_monthly ON district_monthly (district_name, period);
ANALYZE district_monthly;

-- 2.10 mv [from the view]
EXPLAIN (ANALYZE, BUFFERS) SELECT district_name, period, volume_m3 FROM district_monthly WHERE district_name = 'District 5' ORDER BY period;

-- 2.10 base [from base tables]
EXPLAIN (ANALYZE, BUFFERS) SELECT d.name, i.period, SUM(i.volume_m3) AS volume_m3
FROM invoice i JOIN customer c USING (account_no) JOIN district d USING (district_id)
WHERE i.period >= '2026-01-01' AND d.name = 'District 5'
GROUP BY d.name, i.period ORDER BY i.period;

-- 2.10
INSERT INTO meter_reading (meter_id, reading_date, value_m3)
SELECT r.meter_id, DATE '2026-11-01',
       r.value_m3 + round((CASE WHEN m.diameter_mm = 15 THEN 5 + random()*15 ELSE 100 + random()*300 END)::numeric, 2)
FROM meter_reading r
JOIN water_meter m USING (meter_id)
WHERE m.serial_no LIKE 'GM-%' AND r.reading_date = DATE '2026-10-01';

-- 2.10
CALL generate_invoices('2026-10-01');

-- 2.10
REFRESH MATERIALIZED VIEW CONCURRENTLY district_monthly;
