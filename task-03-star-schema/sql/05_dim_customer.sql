-- 05: Customer dimension.
-- region and loyalty_tier are SCD Type 2; phone is SCD Type 1 (overwritten).
-- Key 0 = no loyalty card (not applicable), key -1 = unknown.
CREATE TABLE dim_customer (
    customer_key  SERIAL PRIMARY KEY,
    customer_id   TEXT NOT NULL,                -- natural key (loyalty card number)
    full_name     TEXT NOT NULL,
    phone         TEXT,                         -- Type 1
    city          TEXT,
    region        TEXT NOT NULL,                -- Type 2
    loyalty_tier  TEXT NOT NULL,                -- Type 2
    valid_from    DATE NOT NULL,
    valid_to      DATE NOT NULL DEFAULT '9999-12-31',
    is_current    BOOLEAN NOT NULL DEFAULT TRUE
);

INSERT INTO dim_customer (customer_key, customer_id, full_name, region, loyalty_tier, valid_from) VALUES
(-1, 'UNK', 'Unknown',         'Unknown', 'Unknown', '1900-01-01'),
( 0, 'N/A', 'No loyalty card', 'N/A',     'N/A',     '1900-01-01');

INSERT INTO dim_customer (customer_id, full_name, phone, city, region, loyalty_tier, valid_from) VALUES
('C-10077', 'Dilnoza K.', '+998901110011', 'Samarkand', 'Samarkand',     'silver', '2023-02-14'),
('C-10078', 'Aziz T.',    '+998933330022', 'Tashkent',  'Tashkent city', 'gold',   '2024-06-01');

-- Exactly ONE current row per natural key (partial unique indexes)
CREATE UNIQUE INDEX ux_customer_current ON dim_customer (customer_id) WHERE is_current;
CREATE UNIQUE INDEX ux_store_current    ON dim_store    (store_code)  WHERE is_current;
CREATE UNIQUE INDEX ux_product_current  ON dim_product  (sku)         WHERE is_current;
