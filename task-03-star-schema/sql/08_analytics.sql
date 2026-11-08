-- 08: Analytical queries on the star schema.

-- 8a. Net sales by customer region, as of the time of the sale
SELECT c.region, SUM(f.net_amount) AS net_sales
FROM fact_sales f
JOIN dim_customer c ON c.customer_key = f.customer_key
GROUP BY c.region ORDER BY net_sales DESC;

-- 8b. The same sales by the customer's CURRENT region ("as is today")
SELECT cur.region AS current_region, SUM(f.net_amount) AS net_sales
FROM fact_sales f
JOIN dim_customer hist ON hist.customer_key = f.customer_key
JOIN dim_customer cur  ON cur.customer_id = hist.customer_id AND cur.is_current
GROUP BY cur.region ORDER BY net_sales DESC;

-- 8c. Dairy sales in Samarkand region stores, Q1 2026, by month
SELECT d.year, d.month_num, SUM(f.quantity) AS units, SUM(f.net_amount) AS net_sales
FROM fact_sales f
JOIN dim_date    d ON d.date_key    = f.date_key
JOIN dim_store   s ON s.store_key   = f.store_key
JOIN dim_product p ON p.product_key = f.product_key
WHERE p.category = 'Dairy' AND s.region = 'Samarkand'
  AND d.year = 2026 AND d.quarter = 1
GROUP BY d.year, d.month_num ORDER BY d.month_num;

-- 8d. Average basket on holidays vs normal days (receipt grain built from line grain)
WITH receipts AS (
    SELECT f.receipt_no, d.is_holiday, SUM(f.net_amount) AS receipt_total
    FROM fact_sales f JOIN dim_date d ON d.date_key = f.date_key
    GROUP BY f.receipt_no, d.is_holiday
)
SELECT is_holiday, COUNT(*) AS receipts, ROUND(AVG(receipt_total), 0) AS avg_basket_uzs
FROM receipts GROUP BY is_holiday;

-- 8e. A classic mistake: joining on the NATURAL key duplicates rows
SELECT 'wrong (natural key)' AS method, SUM(f.net_amount)
FROM fact_sales f
JOIN dim_customer c
  ON c.customer_id = (SELECT customer_id FROM dim_customer WHERE customer_key = f.customer_key)
UNION ALL
SELECT 'correct (surrogate key)', SUM(f.net_amount)
FROM fact_sales f JOIN dim_customer c ON c.customer_key = f.customer_key;
