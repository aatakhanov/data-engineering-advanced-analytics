-- 07: Manual SCD Type 2 load. Dilnoza moves to Tashkent on 2026-07-01.
-- Close the current row, then insert a new version.
BEGIN;

UPDATE dim_customer
   SET valid_to = DATE '2026-07-01', is_current = FALSE
 WHERE customer_id = 'C-10077' AND is_current;

INSERT INTO dim_customer (customer_id, full_name, phone, city, region, loyalty_tier, valid_from)
SELECT customer_id, full_name, phone, 'Tashkent', 'Tashkent city', loyalty_tier, DATE '2026-07-01'
  FROM dim_customer
 WHERE customer_id = 'C-10077' AND valid_to = DATE '2026-07-01';

COMMIT;

-- Type 1 change: the phone number is overwritten on ALL versions
UPDATE dim_customer SET phone = '+998901110099' WHERE customer_id = 'C-10077';

-- The July receipt automatically gets the NEW surrogate key
INSERT INTO fact_sales (date_key, store_key, product_key, customer_key,
                        receipt_no, line_no, quantity, unit_price, discount, net_amount, vat_amount)
SELECT 20260712, s.store_key, p.product_key, customer_key_on('C-10077', '2026-07-12'),
       'R-300050', 1, 1, 18000, 0, 18000, 1928.57
FROM dim_store s, dim_product p
WHERE s.store_code = 'S-042' AND s.is_current AND p.sku = 'P-0004' AND p.is_current;

-- Show both versions
SELECT customer_key, customer_id, phone, region, valid_from, valid_to, is_current
FROM dim_customer WHERE customer_id = 'C-10077' ORDER BY valid_from;
