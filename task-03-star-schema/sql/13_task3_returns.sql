-- Task 3: Add a fact_returns table at the grain of ONE RETURNED LINE,
-- linked to the same dimensions, and report net sales minus returns by region.
CREATE TABLE fact_returns (
    return_id           BIGSERIAL PRIMARY KEY,
    date_key            INTEGER  NOT NULL REFERENCES dim_date(date_key),
    store_key           INTEGER  NOT NULL REFERENCES dim_store(store_key),
    product_key         INTEGER  NOT NULL REFERENCES dim_product(product_key),
    customer_key        INTEGER  NOT NULL REFERENCES dim_customer(customer_key),
    return_receipt_no   TEXT     NOT NULL,      -- degenerate dimension
    original_receipt_no TEXT,                   -- degenerate dimension
    line_no             SMALLINT NOT NULL,
    quantity            INTEGER  NOT NULL,
    return_amount       NUMERIC(14,2) NOT NULL,
    vat_amount          NUMERIC(14,2) NOT NULL,
    UNIQUE (return_receipt_no, line_no)
);

CREATE INDEX ix_fact_returns_date     ON fact_returns (date_key);
CREATE INDEX ix_fact_returns_store    ON fact_returns (store_key);
CREATE INDEX ix_fact_returns_product  ON fact_returns (product_key);
CREATE INDEX ix_fact_returns_customer ON fact_returns (customer_key);

-- Dilnoza returns one milk from receipt R-300001 (Samarkand store)
INSERT INTO fact_returns (date_key, store_key, product_key, customer_key,
        return_receipt_no, original_receipt_no, line_no, quantity, return_amount, vat_amount)
SELECT 20260316, s.store_key, p.product_key, customer_key_on('C-10077', '2026-03-16'),
       'RT-9001', 'R-300001', 1, 1, 15000, 1607.14
FROM dim_store s, dim_product p
WHERE s.store_code = 'S-107' AND s.is_current AND p.sku = 'P-0001' AND p.is_current;

-- A cash customer returns one bread from receipt R-300002 (Chilonzor store, version before Task 2)
INSERT INTO fact_returns (date_key, store_key, product_key, customer_key,
        return_receipt_no, original_receipt_no, line_no, quantity, return_amount, vat_amount)
SELECT 20260315, s.store_key, p.product_key, 0,
       'RT-9002', 'R-300002', 1, 1, 4000, 428.57
FROM dim_store s, dim_product p
WHERE s.store_code = 'S-041' AND s.valid_to = DATE '2026-05-15' AND p.sku = 'P-0002' AND p.is_current;

-- Net sales minus returns by region.
-- Each fact is summed separately first; joining two facts directly would multiply rows.
WITH sales AS (
    SELECT s.region, SUM(f.net_amount) AS net_sales
    FROM fact_sales f JOIN dim_store s ON s.store_key = f.store_key
    GROUP BY s.region
), rets AS (
    SELECT s.region, SUM(r.return_amount) AS returns
    FROM fact_returns r JOIN dim_store s ON s.store_key = r.store_key
    GROUP BY s.region
)
SELECT COALESCE(sa.region, re.region) AS region,
       COALESCE(sa.net_sales, 0)  AS net_sales,
       COALESCE(re.returns, 0)    AS returns,
       COALESCE(sa.net_sales, 0) - COALESCE(re.returns, 0) AS net_after_returns
FROM sales sa FULL JOIN rets re ON re.region = sa.region
WHERE COALESCE(sa.region, re.region) <> 'Unknown'
ORDER BY net_after_returns DESC;
