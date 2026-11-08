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
