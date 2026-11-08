-- Task 1: Move product P-0003 from 'Beverages' to a new category
-- 'Functional drinks' from 2026-09-01 using SCD Type 2.
-- Prove that Q1 sales still appear under 'Beverages'.
BEGIN;

UPDATE dim_product SET valid_to = DATE '2026-09-01', is_current = FALSE
 WHERE sku = 'P-0003' AND is_current;

INSERT INTO dim_product (sku, product_name, brand, category, subcategory, unit, weight_g, valid_from)
SELECT sku, product_name, brand, 'Functional drinks', subcategory, unit, weight_g, DATE '2026-09-01'
  FROM dim_product WHERE sku = 'P-0003' AND valid_to = DATE '2026-09-01';

COMMIT;

-- A September sale under the new category
INSERT INTO fact_sales (date_key, store_key, product_key, customer_key,
                        receipt_no, line_no, quantity, unit_price, discount, net_amount, vat_amount)
SELECT 20260915, s.store_key, p.product_key, 0, 'R-300100', 1, 2, 9000, 0, 18000, 1928.57
FROM dim_store s, dim_product p
WHERE s.store_code = 'S-042' AND s.is_current AND p.sku = 'P-0003' AND p.is_current;

-- Both versions of the product
SELECT product_key, sku, category, valid_from, valid_to, is_current
FROM dim_product WHERE sku = 'P-0003' ORDER BY valid_from;

-- Proof: Q1 2026 sales are still under 'Beverages'
SELECT p.category, SUM(f.net_amount) AS net_sales
FROM fact_sales f
JOIN dim_date d    ON d.date_key = f.date_key
JOIN dim_product p ON p.product_key = f.product_key
WHERE p.sku = 'P-0003' AND d.year = 2026 AND d.quarter = 1
GROUP BY p.category;

-- Sales of this product by category and quarter
SELECT p.category, d.quarter, SUM(f.net_amount) AS net_sales
FROM fact_sales f
JOIN dim_date d    ON d.date_key = f.date_key
JOIN dim_product p ON p.product_key = f.product_key
WHERE p.sku = 'P-0003'
GROUP BY p.category, d.quarter ORDER BY d.quarter;
