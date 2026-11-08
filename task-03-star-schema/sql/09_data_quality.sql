-- 09: Data quality tests. Every query must return 0 rows.

-- 9a. No natural key has two current rows
SELECT customer_id, COUNT(*) FROM dim_customer WHERE is_current GROUP BY customer_id HAVING COUNT(*) > 1;

-- 9b. Type 2 validity intervals do not overlap
SELECT a.customer_id
FROM dim_customer a JOIN dim_customer b
  ON a.customer_id = b.customer_id AND a.customer_key <> b.customer_key
 AND a.valid_from < b.valid_to AND b.valid_from < a.valid_to;

-- 9c. Every fact row points to the dimension row that was valid on that date
SELECT f.sales_id
FROM fact_sales f
JOIN dim_date d     ON d.date_key = f.date_key
JOIN dim_customer c ON c.customer_key = f.customer_key
WHERE c.customer_key > 0 AND NOT (d.full_date >= c.valid_from AND d.full_date < c.valid_to);

-- 9d. Reconciliation: line totals equal net_amount
SELECT receipt_no, SUM(quantity * unit_price - discount) - SUM(net_amount) AS diff
FROM fact_sales GROUP BY receipt_no HAVING SUM(quantity * unit_price - discount) <> SUM(net_amount);
