# Part 4: Integration layer, Data Vault for four customer sources

## 4.1 Raw vault design

**Business key of `hub_customer`: PINFL.** It is the only identifier that all sources can be linked to (through KYC), it never changes, and it is unique per person. `client_no`, `card_holder_id`, `app_user_id` and `crm_id` each exist in one system only, and a person can have several of them over time.

Problem: the card, app and CRM systems do not send PINFL. So the vault has a second hub that keeps the source identifiers exactly as they arrive, and a link that connects them to the person once KYC provides the mapping. This way every source is loaded **raw and immediately**, without waiting for identity matching.

| Table | Type | Columns |
|---|---|---|
| `hub_customer` | hub | customer_hk (md5 of PINFL), pinfl, load_date, record_source |
| `hub_source_customer` | hub | src_customer_hk (md5 of system + id), source_system, source_customer_id, load_date, record_source |
| `hub_account` | hub | account_hk, account_no, load_date, record_source |
| `link_customer_identity` | link (same-as) | link_hk, customer_hk, src_customer_hk, load_date, record_source (filled from KYC) |
| `link_customer_account` | link | link_hk, src_customer_hk, account_hk, load_date, record_source |
| `sat_kyc_customer` | satellite on hub_customer | customer_hk, load_date, hash_diff, record_source, full_name, passport_no, risk_rating, sanctions_flag |
| `sat_abs_customer` | satellite on hub_source_customer | src_customer_hk, load_date, hash_diff, record_source, branch_code, client_status |
| `sat_card_customer` | satellite on hub_source_customer | src_customer_hk, load_date, hash_diff, record_source, source_changed_at, address |
| `sat_app_customer` | satellite on hub_source_customer | src_customer_hk, load_date, hash_diff, record_source, phone, device_id |
| `sat_crm_customer` | satellite on hub_source_customer | src_customer_hk, load_date, hash_diff, record_source, source_changed_at, segment, address, relationship_manager |

Alternative rejected: one single hub with PINFL only, with every source loading straight into it. It would force identity matching **before** the raw load, so a card transaction or app record could not be stored until KYC knows the person. It also breaks the vault principle of loading the data as it arrived.

## 4.2 Address conflict after 2026-05-03

The card system sends a new address, the CRM still sends the old one. After the load (SQL in `part4_vault.sql`):

`sat_card_customer`

| load_date | hash_diff | record_source | address |
|---|---|---|---|
| 2025-11-10 | ca8f73ec | CARD | Chilonzor 5, Tashkent |
| 2026-05-03 | ce413d1a | CARD | Yunusobod 12, Tashkent |

`sat_crm_customer` (address column)

| load_date | hash_diff | record_source | address |
|---|---|---|---|
| 2025-11-11 | 7a262533 | CRM | Chilonzor 5, Tashkent |
| 2026-02-12 | 23e94bea | CRM | Chilonzor 5, Tashkent (segment changed to affluent) |

**Nothing was overwritten**, because satellites are insert-only. A new row is added only when `hash_diff` (a hash of all descriptive columns) differs from the latest row of the same key. The card system produced a new hash, so a new row was added and the old one stays. The CRM sent no change, so its hash is the same, and a reload on 2026-05-04 inserted 0 rows. The two sources disagree, and the vault stores both disagreements as facts; deciding which one is right is done later, in the business layer.

## 4.3 Rule for `dim_customer.address`

**Rule: the most recent change wins, with a tie-break CRM before CARD. The dimension also gets `address_source` and `address_changed_at`.**

```sql
WITH candidates AS (
    SELECT l.customer_hk, s.address, 'CARD' AS address_source,
           COALESCE(s.source_changed_at, s.load_date) AS changed_at, 2 AS precedence
    FROM sat_card_customer s JOIN link_customer_identity l USING (src_customer_hk)
    UNION ALL
    SELECT l.customer_hk, s.address, 'CRM',
           COALESCE(s.source_changed_at, s.load_date), 1
    FROM sat_crm_customer s JOIN link_customer_identity l USING (src_customer_hk)
), ranked AS (
    SELECT *, ROW_NUMBER() OVER (PARTITION BY customer_hk ORDER BY changed_at DESC, precedence) AS rn
    FROM candidates WHERE address IS NOT NULL
)
SELECT customer_hk, address, address_source, changed_at AS address_changed_at
FROM ranked WHERE rn = 1;
```

Result for our customer: `Yunusobod 12, Tashkent`, source `CARD`, changed 2026-05-03.

Why this rule: no source is "the truth". CRM addresses are edited by staff and are often stale (as in this example), while the card address comes from the customer. A fixed order "CRM first" would keep showing the old address here. The weakness is that the "most recent" depends on the source change date being correct, so we use the date the source gave us, and fall back to our load date only if it is missing.

## 4.4 Auditor question

"What did the CRM say this customer's segment was on 2026-02-10, and when did you load it?"

```sql
SELECT s.segment, s.source_changed_at, s.load_date
FROM sat_crm_customer s
JOIN hub_source_customer h ON h.src_customer_hk = s.src_customer_hk
WHERE h.source_system = 'CRM' AND h.source_customer_id = 'C-2290'
  AND s.source_changed_at <= TIMESTAMP '2026-02-10 23:59:59'
ORDER BY s.source_changed_at DESC
LIMIT 1;
```

Answer: **affluent**, changed in the CRM on 2026-02-08, **loaded by us on 2026-02-12** (the file was late). If the auditor instead asks what *we knew* on 2026-02-10, filter on `load_date` instead, and the answer is **mass**. The vault can answer both questions because it keeps both dates.

**Why the star schema cannot:** `dim_customer` holds only the cleaned and merged value with a business validity period, so the competing values from losing sources are discarded and we cannot tell what each source said. It also does not record when each value was loaded, and its Type 1 columns and rebuilds overwrite earlier states, so it can never prove what a source file contained at the time.

## 4.5 A new source: the insurance partner

| | Tables to change |
|---|---|
| **(a) Data vault** | **Nothing existing changes.** Add one new satellite `sat_ins_customer` and a loader. The partner ID becomes new rows in `hub_source_customer` (source_system = 'INS'), and `link_customer_identity` gets new rows when KYC maps it to a PINFL. |
| **(b) Star only** | `dim_customer` must be altered (a new ID column and the new attributes), its load logic and the address/segment precedence rules must be rewritten, and an identity-mapping table has to be added or changed. Past history of the partner cannot be rebuilt if the raw files were not kept. |

**Conclusion:** the vault grows by adding tables, so the new source cannot break existing loads or reports. The star-only design grows by modifying the central dimension that every report depends on. The extra effort of the vault pays off as the number of sources grows.
