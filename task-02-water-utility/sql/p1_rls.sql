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
