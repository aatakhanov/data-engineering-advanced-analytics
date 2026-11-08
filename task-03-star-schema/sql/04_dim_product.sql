-- 04: Product dimension. "category" is tracked as SCD Type 2, so moving a
-- product to a new category does not rewrite last year's sales.
CREATE TABLE dim_product (
    product_key  SERIAL PRIMARY KEY,
    sku          TEXT NOT NULL,
    product_name TEXT NOT NULL,
    brand        TEXT,
    category     TEXT NOT NULL,
    subcategory  TEXT,
    unit         TEXT,
    weight_g     INTEGER,
    valid_from   DATE NOT NULL,
    valid_to     DATE NOT NULL DEFAULT '9999-12-31',
    is_current   BOOLEAN NOT NULL DEFAULT TRUE
);

INSERT INTO dim_product (product_key, sku, product_name, category, valid_from)
VALUES (-1, 'UNK', 'Unknown', 'Unknown', '1900-01-01');

INSERT INTO dim_product (sku, product_name, brand, category, subcategory, unit, weight_g, valid_from) VALUES
('P-0001', 'Milk 2.5% 1 l',      'Musaffo', 'Dairy',     'Milk',   'pcs', 1030, '2024-01-01'),
('P-0002', 'Bread (obi non)',    NULL,      'Bakery',    'Bread',  'pcs',  400, '2024-01-01'),
('P-0003', 'Energy drink 0.5 l', 'Flash',   'Beverages', 'Energy', 'pcs',  520, '2024-01-01'),
('P-0004', 'Rice Lazer 1 kg',    'Oltin',   'Grocery',   'Rice',   'pcs', 1000, '2024-01-01');
