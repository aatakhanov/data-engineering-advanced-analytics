-- Task 4: Generate 100,000 random fact rows with generate_series(), then run
-- EXPLAIN with and without indexes and note the difference in execution time.

-- Start without indexes
DROP INDEX IF EXISTS ix_fact_sales_date, ix_fact_sales_store, ix_fact_sales_product, ix_fact_sales_customer;

-- Pick random keys from CURRENT dimension rows only, so dates stay consistent
INSERT INTO fact_sales (date_key, store_key, product_key, customer_key,
                        receipt_no, line_no, quantity, unit_price, discount, net_amount, vat_amount)
SELECT d.date_key, s.store_key, p.product_key, c.customer_key,
       'T4-' || g, 1, q.qty, q.price, 0, q.qty * q.price, ROUND(q.qty * q.price * 12 / 112, 2)
FROM generate_series(1, 100000) AS g
CROSS JOIN LATERAL (SELECT (1 + floor(random()*5))::INT AS qty,
                           (1000 + floor(random()*50)*1000)::NUMERIC AS price, g AS _g) q
JOIN LATERAL (SELECT date_key FROM dim_date WHERE date_key BETWEEN 20260901 AND 20261231
              ORDER BY random() + q._g*0 LIMIT 1) d ON TRUE
JOIN LATERAL (SELECT store_key FROM dim_store WHERE is_current AND store_key > 0
              ORDER BY random() + q._g*0 LIMIT 1) s ON TRUE
JOIN LATERAL (SELECT product_key FROM dim_product WHERE is_current AND product_key > 0
              ORDER BY random() + q._g*0 LIMIT 1) p ON TRUE
JOIN LATERAL (SELECT customer_key FROM dim_customer WHERE is_current AND customer_key >= 0
              ORDER BY random() + q._g*0 LIMIT 1) c ON TRUE;

ANALYZE fact_sales;
SELECT COUNT(*) AS fact_rows FROM fact_sales;

-- 1) Without indexes
EXPLAIN (ANALYZE, BUFFERS)
SELECT s.region, SUM(f.net_amount)
FROM fact_sales f JOIN dim_store s ON s.store_key = f.store_key
GROUP BY s.region;

EXPLAIN (ANALYZE) SELECT SUM(net_amount) FROM fact_sales WHERE date_key = 20261015;

-- 2) Create the indexes
CREATE INDEX ix_fact_sales_date     ON fact_sales (date_key);
CREATE INDEX ix_fact_sales_store    ON fact_sales (store_key);
CREATE INDEX ix_fact_sales_product  ON fact_sales (product_key);
CREATE INDEX ix_fact_sales_customer ON fact_sales (customer_key);
ANALYZE fact_sales;

-- 3) With indexes
EXPLAIN (ANALYZE, BUFFERS)
SELECT s.region, SUM(f.net_amount)
FROM fact_sales f JOIN dim_store s ON s.store_key = f.store_key
GROUP BY s.region;

EXPLAIN (ANALYZE) SELECT SUM(net_amount) FROM fact_sales WHERE date_key = 20261015;
