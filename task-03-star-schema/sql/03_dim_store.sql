-- 03: Store dimension. Surrogate key store_key, natural key store_code.
-- "format" is tracked as SCD Type 2.
CREATE TABLE dim_store (
    store_key    SERIAL PRIMARY KEY,
    store_code   TEXT NOT NULL,                 -- natural key from the source system
    store_name   TEXT NOT NULL,
    city         TEXT NOT NULL,
    region       TEXT NOT NULL,
    format       TEXT NOT NULL,                 -- minimarket / supermarket / hypermarket
    valid_from   DATE NOT NULL,
    valid_to     DATE NOT NULL DEFAULT '9999-12-31',
    is_current   BOOLEAN NOT NULL DEFAULT TRUE
);

INSERT INTO dim_store (store_key, store_code, store_name, city, region, format, valid_from)
VALUES (-1, 'UNK', 'Unknown', 'Unknown', 'Unknown', 'Unknown', '1900-01-01');

INSERT INTO dim_store (store_code, store_name, city, region, format, valid_from) VALUES
('S-041', 'Chilonzor',  'Tashkent',  'Tashkent city', 'minimarket',  '2024-01-01'),
('S-042', 'Yunusobod',  'Tashkent',  'Tashkent city', 'supermarket', '2024-01-01'),
('S-107', 'Registan',   'Samarkand', 'Samarkand',     'supermarket', '2024-01-01'),
('S-203', 'Chust',      'Chust',     'Namangan',      'minimarket',  '2025-03-01');
