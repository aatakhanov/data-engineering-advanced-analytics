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
