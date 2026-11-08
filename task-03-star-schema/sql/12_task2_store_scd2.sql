-- Task 2: Change store S-041 to the 'supermarket' format from 2026-05-15
-- (SCD Type 2) and show sales by format "before" and "after".
BEGIN;

UPDATE dim_store SET valid_to = DATE '2026-05-15', is_current = FALSE
 WHERE store_code = 'S-041' AND is_current;

INSERT INTO dim_store (store_code, store_name, city, region, format, valid_from)
SELECT store_code, store_name, city, region, 'supermarket', DATE '2026-05-15'
  FROM dim_store WHERE store_code = 'S-041' AND valid_to = DATE '2026-05-15';

COMMIT;

-- A June sale ("after" the change)
INSERT INTO fact_sales (date_key, store_key, product_key, customer_key,
                        receipt_no, line_no, quantity, unit_price, discount, net_amount, vat_amount)
SELECT 20260610, s.store_key, p.product_key, 0, 'R-300200', 1, 5, 4000, 0, 20000, 2142.86
FROM dim_store s, dim_product p
WHERE s.store_code = 'S-041' AND s.is_current AND p.sku = 'P-0002' AND p.is_current;

-- Store versions
SELECT store_key, store_code, format, valid_from, valid_to, is_current
FROM dim_store WHERE store_code = 'S-041' ORDER BY valid_from;

-- S-041 sales by format: minimarket before, supermarket after
SELECT s.format, SUM(f.net_amount) AS net_sales
FROM fact_sales f JOIN dim_store s ON s.store_key = f.store_key
WHERE s.store_code = 'S-041'
GROUP BY s.format ORDER BY s.format;

-- All stores by format (state at the time of the sale)
SELECT s.format, SUM(f.net_amount) AS net_sales
FROM fact_sales f JOIN dim_store s ON s.store_key = f.store_key
GROUP BY s.format ORDER BY net_sales DESC;
