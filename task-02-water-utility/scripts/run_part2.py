"""Runs Tasks 2.2 - 2.10 against the 'suvta' database, measures every query with
EXPLAIN (ANALYZE, BUFFERS), and writes: results.json, plans/*.txt, lab3_part2.sql.
The database password is read from the PGPASSWORD environment variable."""
import json, os, re, statistics, subprocess, sys, pathlib

P = r"C:\Program Files\PostgreSQL\18\bin\psql.exe"
ARGS = [P, "-U", "postgres", "-h", "localhost", "-d", "suvta", "-X", "-q", "-At", "-v", "ON_ERROR_STOP=1"]
HERE = pathlib.Path(__file__).parent
(HERE / "plans").mkdir(exist_ok=True)
SQLLOG = open(HERE / "lab3_part2.sql", "w", encoding="utf8")
RESULTS = []

def psql(sql):
    r = subprocess.run(ARGS, input=sql, capture_output=True, text=True, encoding="utf8")
    if r.returncode != 0:
        print("SQL ERROR:", r.stderr, "\nIN:", sql[:300]); sys.exit(1)
    return r.stdout

def log(task, sql):
    SQLLOG.write(f"\n-- {task}\n{sql.strip()}\n"); SQLLOG.flush()

def run(task, sql):
    """Execute and write to the lab file; returns elapsed ms (from \\timing)."""
    log(task, sql)
    out = psql("\\timing on\n" + sql)
    t = [float(x) for x in re.findall(r"Time: ([\d.]+) ms", out)]
    return sum(t)

def size(rel):
    return psql(f"SELECT pg_size_pretty(pg_relation_size('{rel}'))").strip()

def tsize(rel):
    return psql(f"SELECT pg_size_pretty(pg_total_relation_size('{rel}'))").strip()

def measure(task, q, phase, sql, runs=3, size_note="", hide=()):
    stmt = "EXPLAIN (ANALYZE, BUFFERS) " + sql.strip().rstrip(";") + ";"
    if hide:   # hide other indexes for a fair comparison: dropped inside a transaction that is rolled back
        stmt = "BEGIN;\n" + "".join(f"DROP INDEX {h};\n" for h in hide) + stmt + "\nROLLBACK;"
    log(f"{task} {q} [{phase}]", stmt)
    res = []
    for _ in range(runs):
        plan = psql(stmt)
        ms = float(re.search(r"Execution Time: ([\d.]+) ms", plan).group(1))
        res.append((ms, plan))
    res.sort(key=lambda x: x[0])
    ms, plan = res[len(res) // 2]                      # median run
    lines = plan.splitlines()
    scans = [re.sub(r"\s*\(cost.*", "", l).strip(" ->") for l in lines
             if re.search(r"(Seq Scan|Index Scan|Index Only Scan|Bitmap Heap Scan|Bitmap Index Scan)", l)]
    node = scans[0] if scans else lines[0].strip()
    parts = sorted(set(re.findall(r"telemetry_part_\d{4}_\d{2}", plan)))
    row = dict(task=task, query=q, phase=phase, ms=round(ms, 2), all_ms=[round(x[0], 2) for x in res],
               node=node, scans=scans[:4], partitions=parts, size=size_note)
    RESULTS.append(row)
    (HERE / "plans" / f"{task}_{q}_{phase}.txt".replace(" ", "_")).write_text(plan, encoding="utf8")
    print(f"{task:5} {q:6} {phase:22} {ms:10.2f} ms  | {node}  {('['+str(len(parts))+' partitions]') if parts else ''}", flush=True)
    return row

Q = {
 "Q1": "SELECT ts, pressure_bar, flow_m3h FROM telemetry WHERE station_id = 7 AND ts >= '2026-08-15 00:00+05' AND ts < '2026-08-16 00:00+05' ORDER BY ts",
 "Q2": "SELECT station_id, count(*) FROM telemetry WHERE ts >= '2026-10-25 00:00+05' AND pressure_bar < 1.0 GROUP BY station_id",
 "Q3": "SELECT d.name, i.period, SUM(i.volume_m3) AS volume_m3 FROM invoice i JOIN customer c USING (account_no) JOIN district d USING (district_id) WHERE i.period >= '2026-01-01' GROUP BY d.name, i.period",
 "Q4": "SELECT account_no, SUM(amount) AS debt FROM invoice WHERE status <> 'paid' AND issued_on < DATE '2026-10-31' - 60 GROUP BY account_no ORDER BY debt DESC LIMIT 100",
 "Q5": "SELECT account_no, full_name, address FROM customer WHERE address ILIKE '%mustaqillik ko''chasi 17%'",
 "Q6": "SELECT r.reading_date, r.value_m3 FROM meter_reading r JOIN water_meter m USING (meter_id) WHERE m.account_no = 'GN-0012345' ORDER BY r.reading_date",
}
Q1P = Q["Q1"].replace("FROM telemetry", "FROM telemetry_part")
Q2P = Q["Q2"].replace("FROM telemetry", "FROM telemetry_part")

# ---------------- 2.2 baseline ----------------
for k in ["Q1", "Q2", "Q3", "Q4", "Q5", "Q6"]:
    measure("2.2", k, "before", Q[k])

# ---------------- 2.3 index for the station dashboard ----------------
run("2.3", "CREATE INDEX ix_telemetry_station_ts ON telemetry (station_id, ts) INCLUDE (pressure_bar, flow_m3h);")
run("2.3", "VACUUM ANALYZE telemetry;")
measure("2.3", "Q1", "after", Q["Q1"], size_note="ix_telemetry_station_ts " + size("ix_telemetry_station_ts"))

# ---------------- 2.4 BRIN vs B-tree on ts ----------------
# PostgreSQL 18 can also use the covering index from 2.3 for Q2 (skip scan), so it is hidden
# (dropped inside a rolled-back transaction) while BRIN and B-tree are compared.
run("2.4", "CREATE INDEX ix_telemetry_ts_brin ON telemetry USING brin (ts);")
brin_size = size("ix_telemetry_ts_brin")
measure("2.4", "Q2", "BRIN created", Q["Q2"], size_note="BRIN " + brin_size, hide=("ix_telemetry_station_ts",))
run("2.4", "CREATE INDEX ix_telemetry_ts_btree ON telemetry (ts);")
btree_size = size("ix_telemetry_ts_btree")
measure("2.4", "Q2", "BRIN only", Q["Q2"], size_note="BRIN " + brin_size, hide=("ix_telemetry_station_ts", "ix_telemetry_ts_btree"))
measure("2.4", "Q2", "B-tree only", Q["Q2"], size_note="B-tree " + btree_size, hide=("ix_telemetry_station_ts", "ix_telemetry_ts_brin"))
measure("2.4", "Q2", "all indexes present", Q["Q2"], size_note="planner free to choose")
winner = min([r for r in RESULTS if r["task"] == "2.4" and r["phase"] in ("BRIN only", "B-tree only")], key=lambda r: r["ms"])
print("2.4 winner:", winner["phase"], flush=True)
run("2.4", "DROP INDEX ix_telemetry_ts_btree; ANALYZE telemetry;" if winner["phase"] == "BRIN only" else "DROP INDEX ix_telemetry_ts_brin; ANALYZE telemetry;")
RESULTS.append(dict(task="2.4", query="info", phase="kept", ms=None, node=winner["phase"], size=f"BRIN {brin_size} vs B-tree {btree_size}", scans=[], partitions=[], all_ms=[]))

# ---------------- 2.5 partitioning ----------------
months = [("2025-11", "2025-12"), ("2025-12", "2026-01")] + [(f"2026-{m:02d}", f"2026-{m+1:02d}") for m in range(1, 10)] + [("2026-10", "2026-11")]
ddl = ["""CREATE TABLE telemetry_part (
    station_id   INT NOT NULL REFERENCES pumping_station (station_id),
    ts           TIMESTAMPTZ NOT NULL,
    pressure_bar NUMERIC(4,2) CHECK (pressure_bar >= 0),
    flow_m3h     NUMERIC(8,2) CHECK (flow_m3h >= 0)
) PARTITION BY RANGE (ts);"""]
for a, b in months:
    ddl.append(f"CREATE TABLE telemetry_part_{a.replace('-', '_')} PARTITION OF telemetry_part FOR VALUES FROM ('{a}-01 00:00+05') TO ('{b}-01 00:00+05');")
run("2.5", "\n".join(ddl))
copy_ms = run("2.5", "INSERT INTO telemetry_part SELECT * FROM telemetry;")
idx_ms = run("2.5", "CREATE INDEX ix_telemetry_part_station_ts ON telemetry_part (station_id, ts) INCLUDE (pressure_bar, flow_m3h);")
run("2.5", "VACUUM ANALYZE telemetry_part;")
print(f"2.5 copy {copy_ms:.0f} ms, index {idx_ms:.0f} ms", flush=True)
measure("2.5", "Q1", "partitioned", Q1P, size_note="index per partition")
measure("2.5", "Q2", "partitioned", Q2P)
# retention test (the DELETE runs in a transaction that is rolled back, so the data stays for later checks)
del_ms = run("2.5", "BEGIN;\nDELETE FROM telemetry WHERE ts < '2025-12-01 00:00+05';\nROLLBACK;")
det_ms = run("2.5", "ALTER TABLE telemetry_part DETACH PARTITION telemetry_part_2025_11;")
drop_ms = run("2.5", "DROP TABLE telemetry_part_2025_11;")
RESULTS.append(dict(task="2.5", query="retention", phase="DELETE vs DETACH+DROP", ms=None, node=f"DELETE {del_ms:.1f} ms; DETACH {det_ms:.1f} ms + DROP {drop_ms:.1f} ms",
                    size=f"copy {copy_ms:.0f} ms; index {idx_ms:.0f} ms", scans=[], partitions=[], all_ms=[]))
print(f"2.5 retention: DELETE {del_ms:.1f} ms | DETACH {det_ms:.1f} ms + DROP {drop_ms:.1f} ms", flush=True)

# ---------------- 2.6 foreign-key indexes ----------------
run("2.6", "CREATE INDEX ix_water_meter_account ON water_meter (account_no); CREATE INDEX ix_customer_district ON customer (district_id); ANALYZE water_meter; ANALYZE customer;")
measure("2.6", "Q6", "after", Q["Q6"], size_note="ix_water_meter_account " + size("ix_water_meter_account"))
measure("2.6", "Q3", "after", Q["Q3"], size_note="ix_customer_district " + size("ix_customer_district"))

# ---------------- 2.7 partial index for debts ----------------
run("2.7", "CREATE INDEX ix_invoice_open ON invoice (issued_on) INCLUDE (account_no, amount) WHERE status <> 'paid'; VACUUM ANALYZE invoice;")
partial_size = size("ix_invoice_open")
run("2.7", "CREATE INDEX ix_invoice_all ON invoice (issued_on) INCLUDE (account_no, amount);")
full_size = size("ix_invoice_all")
run("2.7", "DROP INDEX ix_invoice_all; ANALYZE invoice;")
measure("2.7", "Q4", "partial index", Q["Q4"], size_note=f"partial {partial_size} vs normal {full_size}")

# ---------------- 2.8 trigram index ----------------
run("2.8", "CREATE EXTENSION IF NOT EXISTS pg_trgm;")
run("2.8", "CREATE INDEX ix_customer_address_trgm ON customer USING gin (address gin_trgm_ops); ANALYZE customer;")
measure("2.8", "Q5", "after", Q["Q5"], size_note="GIN trigram " + size("ix_customer_address_trgm"))

# ---------------- 2.9 rewrite with LAG ----------------
ORIG = """SELECT r.meter_id, r.reading_date,
       r.value_m3 - (SELECT r2.value_m3 FROM meter_reading r2
                     WHERE r2.meter_id = r.meter_id AND r2.reading_date < r.reading_date
                     ORDER BY r2.reading_date DESC LIMIT 1) AS consumption_m3
FROM meter_reading r
WHERE r.reading_date = DATE '2026-10-01'"""
LAGQ = """SELECT meter_id, reading_date, consumption_m3
FROM (SELECT meter_id, reading_date,
             value_m3 - LAG(value_m3) OVER (PARTITION BY meter_id ORDER BY reading_date) AS consumption_m3
      FROM meter_reading
      WHERE reading_date <= DATE '2026-10-01') x
WHERE reading_date = DATE '2026-10-01'"""
measure("2.9", "orig", "correlated subquery", ORIG)
measure("2.9", "lag", "LAG()", LAGQ)
LAGB = """SELECT meter_id, reading_date, consumption_m3
FROM (SELECT meter_id, reading_date,
             value_m3 - LAG(value_m3) OVER (PARTITION BY meter_id ORDER BY reading_date) AS consumption_m3
      FROM meter_reading
      WHERE reading_date BETWEEN DATE '2026-09-01' AND DATE '2026-10-01') x
WHERE reading_date = DATE '2026-10-01'"""
measure("2.9", "lagb", "LAG() 2 months", LAGB)
cmp_sql = f"""SELECT 'original' AS version, COUNT(*) AS row_count, COUNT(consumption_m3) AS non_null, SUM(consumption_m3) AS sum_m3 FROM ({ORIG}) a
UNION ALL SELECT 'LAG', COUNT(*), COUNT(consumption_m3), SUM(consumption_m3) FROM ({LAGQ}) b;"""
log("2.9 compare", cmp_sql)
cmp_out = psql(cmp_sql); print("2.9 compare:\n" + cmp_out, flush=True)
diff_sql = f"SELECT COUNT(*) FROM (({ORIG}) EXCEPT ({LAGQ})) x;"
log("2.9 compare (rows only in the original)", diff_sql)
diff1 = psql(diff_sql).strip()
diff2 = psql(f"SELECT COUNT(*) FROM (({LAGQ}) EXCEPT ({ORIG})) x;").strip()
diff3 = psql(f"SELECT COUNT(*) FROM (({ORIG}) EXCEPT ({LAGB})) x;").strip()
diff4 = psql(f"SELECT COUNT(*) FROM (({LAGB}) EXCEPT ({ORIG})) x;").strip()
RESULTS.append(dict(task="2.9", query="compare2", phase="bounded LAG same rows?", ms=None, node=f"rows only in original: {diff3}; only in bounded LAG: {diff4}", size="", scans=[], partitions=[], all_ms=[]))
RESULTS.append(dict(task="2.9", query="compare", phase="same rows?", ms=None, node=cmp_out.strip().replace("\n", " || "),
                    size=f"rows only in original: {diff1}; only in LAG: {diff2}", scans=[], partitions=[], all_ms=[]))

# ---------------- 2.10 materialized view ----------------
run("2.10", """CREATE MATERIALIZED VIEW district_monthly AS
SELECT d.name AS district_name, i.period, SUM(i.volume_m3) AS volume_m3
FROM invoice i JOIN customer c USING (account_no) JOIN district d USING (district_id)
WHERE i.period >= '2026-01-01'
GROUP BY d.name, i.period;
CREATE UNIQUE INDEX ux_district_monthly ON district_monthly (district_name, period);
ANALYZE district_monthly;""")
measure("2.10", "mv", "from the view", "SELECT district_name, period, volume_m3 FROM district_monthly WHERE district_name = 'District 5' ORDER BY period",
        size_note="view " + tsize("district_monthly"))
measure("2.10", "base", "from base tables", """SELECT d.name, i.period, SUM(i.volume_m3) AS volume_m3
FROM invoice i JOIN customer c USING (account_no) JOIN district d USING (district_id)
WHERE i.period >= '2026-01-01' AND d.name = 'District 5'
GROUP BY d.name, i.period ORDER BY i.period""")
before_oct = psql("SELECT COUNT(*) FROM district_monthly WHERE period = '2026-10-01'").strip()
ins_ms = run("2.10", """INSERT INTO meter_reading (meter_id, reading_date, value_m3)
SELECT r.meter_id, DATE '2026-11-01',
       r.value_m3 + round((CASE WHEN m.diameter_mm = 15 THEN 5 + random()*15 ELSE 100 + random()*300 END)::numeric, 2)
FROM meter_reading r
JOIN water_meter m USING (meter_id)
WHERE m.serial_no LIKE 'GM-%' AND r.reading_date = DATE '2026-10-01';""")
inv_ms = run("2.10", "CALL generate_invoices('2026-10-01');")
ref_ms = run("2.10", "REFRESH MATERIALIZED VIEW CONCURRENTLY district_monthly;")
after_oct = psql("SELECT COUNT(*), ROUND(SUM(volume_m3),0) FROM district_monthly WHERE period = '2026-10-01'").strip()
chk = psql("""SELECT COUNT(*) AS gm_meters, COUNT(*) FILTER (WHERE n.value_m3 > o.value_m3) AS higher_than_october
FROM water_meter m JOIN meter_reading o ON o.meter_id = m.meter_id AND o.reading_date = '2026-10-01'
JOIN meter_reading n ON n.meter_id = m.meter_id AND n.reading_date = '2026-11-01' WHERE m.serial_no LIKE 'GM-%'""").strip()
RESULTS.append(dict(task="2.10", query="refresh", phase="steps", ms=None,
    node=f"Nov readings insert {ins_ms:.0f} ms; generate_invoices(Oct) {inv_ms:.0f} ms; REFRESH CONCURRENTLY {ref_ms:.0f} ms; Oct rows in view before={before_oct}, after={after_oct}; check={chk}",
    size="", scans=[], partitions=[], all_ms=[]))
print("2.10:", RESULTS[-1]["node"], flush=True)

json.dump(RESULTS, open(HERE / "results.json", "w"), indent=1)
print("DONE")
