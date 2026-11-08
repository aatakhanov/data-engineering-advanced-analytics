"""Builds results_log.md and lab3.sql from the measured results."""
import json, re, pathlib
H = pathlib.Path(__file__).parent
R = json.load(open(H / "results.json", encoding="utf8"))
def get(task, q, phase):
    for r in R:
        if r["task"] == task and r["query"] == q and r["phase"] == phase: return r
def f(r): return f"{r['ms']:.2f}" if r and r.get("ms") is not None else "-"
def node(r): return (r["node"] if r else "-").replace("|", "/")
def parts(task, q, phase):
    p = (H / "plans" / f"{task}_{q}_{phase}.txt".replace(" ", "_"))
    t = p.read_text(encoding="utf8")
    return sorted(set(re.findall(r"telemetry_part_\d{4}_\d{2}", t)))

rows = []
def add(task, q, b, a, size):
    rows.append(f"| {task} | {q} | {f(b)} | {f(a)} | {node(b)} | {node(a)} | {size} |")

base = {k: get("2.2", k, "before") for k in ["Q1", "Q2", "Q3", "Q4", "Q5", "Q6"]}
for k in ["Q1", "Q2", "Q3", "Q4", "Q5", "Q6"]:
    rows.append(f"| 2.2 | {k} (baseline) | {f(base[k])} | - | {node(base[k])} | - | - |")
a = get("2.3", "Q1", "after");                add("2.3", "Q1 covering index", base["Q1"], a, a["size"])
b1 = get("2.4", "Q2", "BRIN created");        add("2.4", "Q2 BRIN", base["Q2"], b1, b1["size"])
b2 = get("2.4", "Q2", "BRIN only");           add("2.4", "Q2 BRIN only", base["Q2"], b2, b2["size"])
b3 = get("2.4", "Q2", "B-tree only");         add("2.4", "Q2 B-tree only", base["Q2"], b3, b3["size"])
p1 = get("2.5", "Q1", "partitioned");         add("2.5", "Q1 partitioned", base["Q1"], p1, "partitions scanned: " + ", ".join(parts("2.5", "Q1", "partitioned")))
p2 = get("2.5", "Q2", "partitioned");         add("2.5", "Q2 partitioned", base["Q2"], p2, "partitions scanned: " + ", ".join(parts("2.5", "Q2", "partitioned")))
ret = get("2.5", "retention", "DELETE vs DETACH+DROP")
c = get("2.6", "Q6", "after");                add("2.6", "Q6 FK index", base["Q6"], c, c["size"])
c = get("2.6", "Q3", "after");                add("2.6", "Q3 FK index", base["Q3"], c, c["size"])
c = get("2.7", "Q4", "partial index");        add("2.7", "Q4 partial index", base["Q4"], c, c["size"])
c = get("2.8", "Q5", "after");                add("2.8", "Q5 trigram", base["Q5"], c, c["size"])
o = get("2.9", "orig", "correlated subquery"); l = get("2.9", "lag", "LAG()"); lb = get("2.9", "lagb", "LAG() 2 months")
add("2.9", "October report: correlated vs LAG()", o, l, "same rows: " + get("2.9", "compare", "same rows?")["size"])
add("2.9", "extra: correlated vs LAG() on 2 months", o, lb, get("2.9", "compare2", "bounded LAG same rows?")["node"])
m = get("2.10", "base", "from base tables"); v = get("2.10", "mv", "from the view")
add("2.10", "district 'District 5': base tables vs view", m, v, v["size"])

md = ["# Results log (Exercise Pack 3, Water Utility)", "",
      "Timings are the **median of 3 runs** of `EXPLAIN (ANALYZE, BUFFERS)` (execution time, warm cache), PostgreSQL 18 on a laptop. Full plans are in `plans/`.", "",
      "| Task | Query | Time before (ms) | Time after (ms) | Plan before | Plan after | Index or table size |",
      "|---|---|---|---|---|---|---|"] + rows
md += ["", "## Extra notes", "",
       f"- 2.5 retention: {ret['node']} ({ret['size']}).",
       f"- 2.4 kept index: {get('2.4','info','kept')['node']} ({get('2.4','info','kept')['size']}).",
       f"- 2.10 steps: {get('2.10','refresh','steps')['node']}."]
(H / "results_log.md").write_text("\n".join(md) + "\n", encoding="utf8")
print("\n".join(md))
