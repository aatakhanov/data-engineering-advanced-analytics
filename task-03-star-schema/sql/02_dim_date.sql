-- 02: Date dimension, one row per day from 2020 to 2035.
CREATE TABLE dim_date (
    date_key      INTEGER PRIMARY KEY,          -- e.g. 20261107
    full_date     DATE NOT NULL UNIQUE,
    day_of_month  SMALLINT NOT NULL,
    day_name      TEXT NOT NULL,
    week_of_year  SMALLINT NOT NULL,
    month_num     SMALLINT NOT NULL,
    month_name    TEXT NOT NULL,
    quarter       SMALLINT NOT NULL,
    year          SMALLINT NOT NULL,
    is_weekend    BOOLEAN NOT NULL,
    is_holiday    BOOLEAN NOT NULL DEFAULT FALSE,
    holiday_name  TEXT
);

INSERT INTO dim_date
SELECT  TO_CHAR(d, 'YYYYMMDD')::INT,
        d,
        EXTRACT(DAY FROM d),
        TO_CHAR(d, 'Day'),
        EXTRACT(WEEK FROM d),
        EXTRACT(MONTH FROM d),
        TO_CHAR(d, 'Month'),
        EXTRACT(QUARTER FROM d),
        EXTRACT(YEAR FROM d),
        EXTRACT(ISODOW FROM d) IN (6, 7),
        FALSE, NULL
FROM generate_series('2020-01-01'::DATE, '2035-12-31'::DATE, '1 day') AS d;

-- Fixed-date public holidays. Religious holidays move every year,
-- so add them separately each year from the official list.
UPDATE dim_date SET is_holiday = TRUE, holiday_name = CASE
    WHEN month_num = 1  AND day_of_month = 1  THEN 'New Year'
    WHEN month_num = 3  AND day_of_month = 8  THEN 'Women''s Day'
    WHEN month_num = 3  AND day_of_month = 21 THEN 'Navruz'
    WHEN month_num = 5  AND day_of_month = 9  THEN 'Remembrance and Honor Day'
    WHEN month_num = 9  AND day_of_month = 1  THEN 'Independence Day'
    WHEN month_num = 10 AND day_of_month = 1  THEN 'Teachers'' Day'
    WHEN month_num = 12 AND day_of_month = 8  THEN 'Constitution Day'
END
WHERE (month_num, day_of_month) IN ((1,1),(3,8),(3,21),(5,9),(9,1),(10,1),(12,8));

-- "Unknown" member
INSERT INTO dim_date VALUES (-1, '1900-01-01', 1, 'Unknown', 1, 1, 'Unknown', 1, 1900, FALSE, FALSE, NULL);
