"""Extract the result CSVs and the query catalog into out/data.json and out/data.js, the data of the start page, and
the queries' reference results into out/results/.

    python3 site/extract.py [prefix ...]    only the configurations whose names start with a prefix (e.g. sf1-)
"""
import glob, json, math, os, re, csv, subprocess, sys, tomllib
from collections import defaultdict

HERE = os.path.dirname(os.path.abspath(__file__))  # site/: the scripts, templates, stylesheet and fonts
ROOT = os.path.dirname(HERE)                         # the repository
OUT = os.path.join(HERE, "out")                      # everything built; not checked in
# the results: systems/<system>/results/<date>/<config>.csv, of every system and configuration the newest, so
# that a rerun of some systems replaces only their results of an earlier run

# What ran, kept with the results by the runner (<config>.json next to <config>.csv): every system of a
# configuration must have run with the same settings, or the configuration's results do not compare
SAME = ["sf", "threads", "cpuset", "memory", "query_timeout", "load_timeout", "grace_period", "repetitions", "keys", "queries",
        "benchmark", "host"]
# only these configurations, by prefix of their names (default: all)
ONLY = sys.argv[1:]

# systems not shown (none at the moment)
HIDDEN = set()
# configurations not shown (none at the moment)
HIDDEN_CONFIGS = set()

# the benchmark as it is (data, queries, runner) starts with the run of 15 October 2026; earlier
# results do not compare with it
SINCE = "2026-10-15"

LATEST = {}  # (system, config): the newest results file
for path in sorted(glob.glob(f"{ROOT}/systems/*/results/????-??-??/*.csv")):
    if path.endswith(".errors.csv"):
        continue
    system, date, cfg = path.split("/")[-4], path.split("/")[-2], os.path.basename(path)[:-4]
    if date < SINCE or system in HIDDEN or cfg in HIDDEN_CONFIGS or (ONLY and not cfg.startswith(tuple(ONLY))):
        continue
    LATEST[(system, cfg)] = path  # sorted: a later date replaces an earlier one
DATES = sorted({path.split("/")[-2] for path in LATEST.values()})

# the system a system is based on (based_on in its system.toml, docs/RUNNER.md, e.g. PostgreSQL of its extensions):
# the site shows a variant under its base, when asked to, and leaves the variants out where systems are compared (the
# fastest system, the Pareto front)
BASED_ON = {f.split("/")[-2]: tomllib.load(open(f, "rb")).get("based_on") for f in glob.glob(f"{ROOT}/systems/*/system.toml")}

records, bench = {}, {}
for (system, cfg), path in sorted(LATEST.items()):
    date = path.split("/")[-2]
    meta = path[:-4] + ".json"
    assert os.path.isfile(meta), f"{os.path.relpath(path, ROOT)} has no {os.path.basename(meta)}: the results do not say how they were run"
    r = records[(cfg, system)] = json.load(open(meta))
    assert (r["system"], r["config"], r["date"]) == (system, cfg, date), f"{os.path.relpath(meta, ROOT)}: is about {r['system']}, {r['config']}, {r['date']}"
    facts = {k: r.get(k) for k in SAME}
    first = bench.setdefault(cfg, dict(facts, system=system))
    diff = [k for k in SAME if first[k] != facts[k]]
    assert not diff, f"{cfg}: {system} and {first['system']} ran with different {', '.join(diff)}"

configs = {}
# why queries failed, in each system's words: the message column of the results, or <config>.errors.csv
# next to them (the runners of 15 and 16 October)
messages = {}
for (system, cfg), path in sorted(LATEST.items()):
    for r in csv.DictReader(open(path)):
        c = configs.setdefault(cfg, defaultdict(lambda: {"runs": defaultdict(dict), "load": {}, "failed": None}))
        s = c[system]
        run = int(r["run"])
        if r["status"].startswith("failed_"):
            s["failed"] = {"run": run, "status": r["status"], "query": r["query"]}
            continue
        if r.get("message"):
            messages.setdefault((cfg, system), {})[(run, r["query"])] = (r["status"], r["message"])
        t = float(r["median_s"]) if r["median_s"] else None
        if r["query"] == "load":
            s["load"][run] = t
        else:
            s["runs"][run][r["query"]] = (t, r["status"])

for (system, cfg), path in LATEST.items():
    path = path[:-4] + ".errors.csv"
    if not os.path.isfile(path):
        continue
    for r in csv.DictReader(open(path)):
        messages.setdefault((cfg, system), {})[(int(r["run"]), r["query"])] = (r["status"], r["message"])

# The query as the benchmark runs it (workload/queries), its placeholders spelled the standard way: every point's
# default (dbo-bench points), the innermost placeholder first, as they nest
POINTS = {p["name"]: p for p in json.loads(subprocess.run([f"{ROOT}/target/release/dbo-bench", "points"], capture_output=True,
                                                          text=True, check=True).stdout)}

def top_level_args(text):
    """The arguments of a placeholder, split at the commas outside parentheses and quotes."""
    out, depth, quote, cur = [], 0, False, ""
    for ch in text:
        if ch == "'":
            quote = not quote
        elif not quote and ch == "(":
            depth += 1
        elif not quote and ch == ")":
            depth -= 1
        elif not quote and depth == 0 and ch == ",":
            out.append(cur.strip()); cur = ""; continue
        cur += ch
    return out + [cur.strip()]

def standard_sql(sql):
    while "{{" in sql:
        i = sql.rindex("{{")  # the last opening is an innermost placeholder
        j = sql.index("(", i)
        name, depth, quote, k = sql[i + 2:j], 0, False, j
        for k in range(j, len(sql)):
            ch = sql[k]
            if ch == "'":
                quote = not quote
            elif not quote and ch == "(":
                depth += 1
            elif not quote and ch == ")":
                depth -= 1
                if depth == 0:
                    break
        assert sql[k + 1:k + 3] == "}}", f"placeholder {name} at {i}: no closing }}}}"
        point, args = POINTS[name], top_level_args(sql[j + 1:k])
        assert len(args) == len(point["params"]), f"{name}: {args}"
        text = point["default"]
        for param, arg in zip(point["params"], args):
            text = text.replace("{" + param + "}", arg)
        sql = sql[:i] + text + sql[k + 3:]
    return sql

# a system is disabled from its scale limit on (scale_limit in its system.toml, inclusive): instead of any
# results there, the configuration shows why (scale_limit_message)
for cfg, c in configs.items():
    for system in sorted({s for s, _ in LATEST}):
        spec = tomllib.load(open(f"{ROOT}/systems/{system}/system.toml", "rb"))
        if spec.get("scale_limit") is not None and bench[cfg]["sf"] >= spec["scale_limit"]:
            c[system] = {"runs": defaultdict(dict), "load": {}, "failed": {"run": 1, "status": "disabled", "query": "", "message": spec["scale_limit_message"]}}
            records.setdefault((cfg, system), {})
            messages.pop((cfg, system), None)

catalog = json.load(open(f"{ROOT}/workload/catalog.json"))
queries = []
for e in catalog["entries"]:
    queries.append({
        "id": e["id"],
        "title": e["title"],
        "question": e["question"],
        "role": e["sources"][0]["trace"].split("/")[1] if e["sources"] else None,
        "tables": e["tables"],
        "rows": (e.get("profile") or {}).get("rows"),
        # what the benchmark runs, not the SQL as the role play wrote it (the query pages show both)
        "sql": standard_sql(open(f"{ROOT}/workload/queries/{e['id']}.sql").read().strip()),
    })
qids = [q["id"] for q in queries]

personas = json.load(open(f"{ROOT}/roleplay/personas.json"))
roles = {m["id"]: m["title"] for m in personas["managers"]}

# a result not checked (no reference results for the scale factor) counts as correct; the configuration says so
STATUS = {"ok": 0, "unchecked": 0, "wrong_result": 1, "error": 2, "timeout": 3}

out = {"dates": DATES, "roles": roles, "queries": queries, "based_on": {s: b for s, b in sorted(BASED_ON.items()) if b}, "configs": {}}
for cfg, systems in configs.items():
    m = re.match(r"sf(\d+)-(.*)", cfg)
    REPS, TIMEOUT = bench[cfg]["repetitions"], float(bench[cfg]["query_timeout"])
    assert float(m.group(1)) == bench[cfg]["sf"], f"{cfg}: the name does not match sf {bench[cfg]['sf']}"
    last = {}
    for name, s in systems.items():
        runs = s["runs"]
        final = runs.get(5, {})
        t, st = [], []
        for q in qids:
            v = final.get(q)
            if v is None:
                t.append(None); st.append(4)  # not run (failed run)
            else:
                t.append(v[0]); st.append(STATUS.get(v[1], 2))
        last[name] = (t, st)
    # per-query best correct time across systems (without the children)
    best = []
    for i in range(len(qids)):
        ok = [last[n][0][i] for n in last if not BASED_ON.get(n) and last[n][1][i] == 0 and last[n][0][i] is not None]
        best.append(min(ok) if ok else None)
    # what a query without a correct result counts as: a timeout the timeout; an error, a wrong result or a query not
    # run twice the slowest correct time of that query (the timeout if no system answered it)
    worst = [max((last[n][0][i] for n in last if not BASED_ON.get(n) and last[n][1][i] == 0 and last[n][0][i] is not None), default=TIMEOUT / 2)
             for i in range(len(qids))]
    cost = lambda t, st, i: t[i] if st[i] == 0 else TIMEOUT if st[i] == 3 else 2 * worst[i]
    sysout = {}
    for name, s in systems.items():
        t, st = last[name]
        # geometric mean of (t + 10 ms) / (best + 10 ms) over all queries, ClickBench style
        logs = []
        for i, q in enumerate(qids):
            if best[i] is None:
                continue
            logs.append(math.log((cost(t, st, i) + 0.01) / (best[i] + 0.01)))
        # per-run geometric mean over the queries that succeeded in every run of this system
        per_run = []
        common = [q for q in qids if all(s["runs"].get(r, {}).get(q, (None, ""))[1] in ("ok", "wrong_result", "unchecked") for r in range(1, 6))]
        for run in range(1, 6):
            xs = [s["runs"][run][q][0] for q in common]
            per_run.append(math.exp(sum(math.log(x) for x in xs) / len(xs)) if xs else None)
        # estimated seconds of the whole run: every load, plus every repetition of every query after every load;
        # a timeout costs one attempt of TIMEOUT (the query is then skipped until the next load), an error nothing
        query_s, query_ok = 0.0, 0
        for run in s["runs"].values():
            for qt, qs in run.values():
                query_s += REPS * qt if qt is not None else TIMEOUT if qs == "timeout" else 0.0
                query_ok += REPS if qs == "ok" else 0
        last_run = max(s["runs"]) if s["runs"] else 0
        msgs = {qids.index(q): m for (run, q), (_, m) in messages.get((cfg, name), {}).items() if run == last_run and q in qids}
        sysout[name] = {
            "version": records[(cfg, name)].get("version"),  # `version` in the system's system.toml
            "messages": {str(i): m for i, m in sorted(msgs.items())},
            "run_s": {"load": sum(v for v in s["load"].values() if v), "queries": query_s},
            "run_ok": query_ok,  # query executions in the run that returned a result counted as correct
            "times": [None if x is None else round(x, 6) for x in t],
            "status": st,
            "score": math.exp(sum(logs) / len(logs)) if logs else None,  # None: no query answered by any system
            "unchecked": sum(1 for _, qs in s["runs"].get(5, {}).values() if qs == "unchecked"),
            "correct": sum(1 for x in st if x == 0),
            "wrong": sum(1 for x in st if x == 1),
            "error": sum(1 for x in st if x == 2),
            "timeout": sum(1 for x in st if x == 3),
            "load": [s["load"].get(r) for r in range(1, 6)],
            "per_run": per_run,
            "per_run_n": len(common),
            "failed": s["failed"],
        }
    out["configs"][cfg] = {"sf": int(m.group(1)), "machine": m.group(2), "timeout": TIMEOUT, "worst": [round(w, 6) for w in worst],
                           "threads": bench[cfg]["threads"], "memory": bench[cfg]["memory"], "benchmark": bench[cfg]["benchmark"],
                           "cpuset": bench[cfg]["cpuset"], "host": bench[cfg]["host"],  # the server that ran it
                           "reps": REPS, "best": best, "systems": sysout,
                           # the results were not checked: no reference results for the scale factor
                           "unchecked": any(s["unchecked"] for s in sysout.values())}

os.makedirs(OUT, exist_ok=True)

# The reference result of every query at every scale factor, after the last load, for the start page's query panel:
# out/results/sf<sf>/qNNN.json, its first rows and its number of rows (NULL: null)
RESULT_ROWS = 100
for d in sorted(glob.glob(f"{ROOT}/workload/results/sf*/through-2025-Q4")):
    sf = d.split("/")[-2]
    os.makedirs(os.path.join(OUT, "results", sf), exist_ok=True)
    for q in queries:
        rows = list(csv.reader(open(f"{d}/{q['id']}.csv")))
        json.dump({"rows": [[v if v != "" else None for v in r] for r in rows[:RESULT_ROWS]], "total": len(rows)},
                  open(os.path.join(OUT, "results", sf, f"{q['id']}.json"), "w"), separators=(",", ":"))

json.dump(out, open(os.path.join(OUT, "data.json"), "w"), separators=(",", ":"))
for cfg, c in out["configs"].items():
    print(cfg)
    for n, s in sorted(c["systems"].items(), key=lambda kv: kv[1]["score"]):
        print(f"  {n:15s} {s['score']:8.2f}  {s['correct']:3d} ok  {s['wrong']:3d} wrong  {s['error']:3d} err  {s['timeout']:3d} to  load {s['load'][0]}")
with open(os.path.join(OUT, "data.js"), "w") as f:
    f.write("window.DATA = ")
    json.dump(out, f, separators=(",", ":"))
    f.write(";\n")
