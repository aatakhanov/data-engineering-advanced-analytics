-- 10: Compare the query plan before and after indexing the foreign keys.
-- In pgAdmin use Explain > Analyze (F7), or run EXPLAIN as below.
EXPLAIN (ANALYZE, BUFFERS)
SELECT s.region, SUM(f.net_amount)
FROM fact_sales f JOIN dim_store s ON s.store_key = f.store_key
GROUP BY s.region;

CREATE INDEX ix_fact_sales_date     ON fact_sales (date_key);
CREATE INDEX ix_fact_sales_store    ON fact_sales (store_key);
CREATE INDEX ix_fact_sales_product  ON fact_sales (product_key);
CREATE INDEX ix_fact_sales_customer ON fact_sales (customer_key);
