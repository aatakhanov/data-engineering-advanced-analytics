-- 06: Sales fact table. Grain = ONE RECEIPT LINE.
-- Only keys and measures; receipt_no is a degenerate dimension.
CREATE TABLE fact_sales (
    sales_id      BIGSERIAL PRIMARY KEY,
    date_key      INTEGER  NOT NULL REFERENCES dim_date(date_key),
    store_key     INTEGER  NOT NULL REFERENCES dim_store(store_key),
    product_key   INTEGER  NOT NULL REFERENCES dim_product(product_key),
    customer_key  INTEGER  NOT NULL REFERENCES dim_customer(customer_key),
    receipt_no    TEXT     NOT NULL,            -- degenerate dimension
    line_no       SMALLINT NOT NULL,
    quantity      INTEGER  NOT NULL,
    unit_price    NUMERIC(14,2) NOT NULL,       -- money in UZS, never FLOAT
    discount      NUMERIC(14,2) NOT NULL DEFAULT 0,
    net_amount    NUMERIC(14,2) NOT NULL,
    vat_amount    NUMERIC(14,2) NOT NULL,
    UNIQUE (receipt_no, line_no)                -- grain uniqueness test
);

-- Helper: returns the surrogate key that was valid on the transaction date.
CREATE OR REPLACE FUNCTION customer_key_on(p_customer_id TEXT, p_date DATE)
RETURNS INTEGER LANGUAGE sql STABLE AS $$
    SELECT COALESCE(
        (SELECT customer_key FROM dim_customer
          WHERE customer_id = p_customer_id
            AND p_date >= valid_from AND p_date < valid_to), -1);
$$;

-- Dilnoza (C-10077): receipt R-300001 in March
INSERT INTO fact_sales (date_key, store_key, product_key, customer_key,
                        receipt_no, line_no, quantity, unit_price, discount, net_amount, vat_amount)
SELECT 20260314, s.store_key, p.product_key, customer_key_on('C-10077', '2026-03-14'),
       'R-300001', 1, 2, 15000, 0, 30000, 3214.29
FROM dim_store s, dim_product p
WHERE s.store_code = 'S-107' AND s.is_current AND p.sku = 'P-0001' AND p.is_current;

INSERT INTO fact_sales (date_key, store_key, product_key, customer_key,
                        receipt_no, line_no, quantity, unit_price, discount, net_amount, vat_amount)
SELECT 20260314, s.store_key, p.product_key, customer_key_on('C-10077', '2026-03-14'),
       'R-300001', 2, 1, 9000, 1000, 8000, 857.14
FROM dim_store s, dim_product p
WHERE s.store_code = 'S-107' AND s.is_current AND p.sku = 'P-0003' AND p.is_current;

-- Cash sale without a loyalty card -> customer_key 0
INSERT INTO fact_sales (date_key, store_key, product_key, customer_key,
                        receipt_no, line_no, quantity, unit_price, discount, net_amount, vat_amount)
SELECT 20260314, s.store_key, p.product_key, 0,
       'R-300002', 1, 3, 4000, 0, 12000, 1285.71
FROM dim_store s, dim_product p
WHERE s.store_code = 'S-041' AND s.is_current AND p.sku = 'P-0002' AND p.is_current;
