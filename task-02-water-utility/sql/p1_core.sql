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
