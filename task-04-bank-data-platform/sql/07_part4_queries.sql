SET search_path TO vault;

\echo '=== 4.2 sat_card_customer: two rows, nothing overwritten'
SELECT load_date, LEFT(hash_diff,8) AS hash_diff, record_source, address FROM sat_card_customer ORDER BY load_date;
\echo '=== 4.2 sat_crm_customer: the CRM still holds the old address (no new row on 05-04)'
SELECT load_date, LEFT(hash_diff,8) AS hash_diff, record_source, segment, address FROM sat_crm_customer ORDER BY load_date;

-- ---------- 4.3 address rule ----------
-- Most recent change wins (source_changed_at, else load_date). Ties: CRM > CARD.
CREATE OR REPLACE VIEW v_customer_address AS
WITH candidates AS (
    SELECT l.customer_hk, s.address, 'CARD' AS address_source,
           COALESCE(s.source_changed_at, s.load_date) AS changed_at, 2 AS precedence, s.load_date
    FROM sat_card_customer s JOIN link_customer_identity l ON l.src_customer_hk = s.src_customer_hk
    UNION ALL
    SELECT l.customer_hk, s.address, 'CRM',
           COALESCE(s.source_changed_at, s.load_date), 1, s.load_date
    FROM sat_crm_customer s JOIN link_customer_identity l ON l.src_customer_hk = s.src_customer_hk
), ranked AS (
    SELECT *, ROW_NUMBER() OVER (PARTITION BY customer_hk ORDER BY changed_at DESC, precedence) AS rn
    FROM candidates WHERE address IS NOT NULL
)
SELECT customer_hk, address, address_source, changed_at AS address_changed_at
FROM ranked WHERE rn = 1;

\echo '=== 4.3 resolved address with the winning source'
SELECT address, address_source, address_changed_at FROM v_customer_address;

-- ---------- 4.4 auditor ----------
\echo '=== 4.4 what did the CRM say the segment was on 2026-02-10, and when did we load it?'
SELECT s.segment, s.source_changed_at, s.load_date
FROM sat_crm_customer s
JOIN hub_source_customer h ON h.src_customer_hk = s.src_customer_hk
WHERE h.source_system = 'CRM' AND h.source_customer_id = 'C-2290'
  AND s.source_changed_at <= TIMESTAMP '2026-02-10 23:59:59'
ORDER BY s.source_changed_at DESC LIMIT 1;

\echo '=== 4.4 what did WE know on 2026-02-10 (what had been loaded by then)?'
SELECT s.segment, s.load_date
FROM sat_crm_customer s
JOIN hub_source_customer h ON h.src_customer_hk = s.src_customer_hk
WHERE h.source_system = 'CRM' AND h.source_customer_id = 'C-2290'
  AND s.load_date <= TIMESTAMP '2026-02-10 23:59:59'
ORDER BY s.load_date DESC LIMIT 1;

\echo '=== vault integrity: every source id maps to exactly one customer (must be 0 rows)'
SELECT src_customer_hk FROM link_customer_identity GROUP BY src_customer_hk HAVING COUNT(*) > 1;
