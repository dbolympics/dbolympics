#!/usr/bin/env python3
"""The types of every division's operands in the canonical queries: workload/queries/divisions.json.

    python3 tools/division_types.py      (then python3 tools/canonical.py)

tools/canonical.py turns a division of integers or decimals into a placeholder by the types of
its operands, `{{divide_int(a, b)}}` for two integers and `{{divide_decimal(a, b)}}` for a decimal
and a decimal or an integer (docs/DIALECTS.md), so that a system that divides one of them
differently can say how. The types come from DuckDB, on the empty schema: each division in turn
becomes `ascii(a, b)`, a call no function matches, and the binder's error names the types of a
and b. A double, an interval or anything else is None: the division stays `a / b`.

divisions.json lists per query one entry per `/`, in the order of the canonical text before the
placeholders: "int", "decimal" or null.
Needs `duckdb` (the CLI) and target/release/dbo-bench, which renders the queries for DuckDB.
"""

import json
import re
import subprocess
import sys
import tempfile
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import canonical  # noqa: E402

ROOT = canonical.ROOT
INTEGER = {"TINYINT", "SMALLINT", "INTEGER", "BIGINT", "HUGEINT", "UTINYINT", "USMALLINT", "UINTEGER",
           "UBIGINT", "UHUGEINT", "INTEGER_LITERAL"}
ERROR = re.compile(r"argument types 'ascii\((.*)\)'")


def kind(t):
    t = t.strip().strip('"')
    return "int" if t in INTEGER else "decimal" if t.startswith("DECIMAL") else None


def types(sql):
    """The DuckDB types of `ascii(a, b)` in a rendered probe, from the binder's error."""
    r = subprocess.run(["duckdb", ":memory:"], input=sql, capture_output=True, text=True)
    m = ERROR.search(r.stdout + r.stderr)
    if not m:
        raise ValueError(f"no types in DuckDB's answer: {(r.stdout + r.stderr)[-500:]}")
    depth, cut = 0, None  # the top-level comma between the two types (DECIMAL(14,4) has one too)
    for i, c in enumerate(m.group(1)):
        depth += c == "("
        depth -= c == ")"
        if c == "," and depth == 0:
            cut = i
    a, b = kind(m.group(1)[:cut]), kind(m.group(1)[cut + 1:])
    return None if a is None or b is None else "int" if a == b == "int" else "decimal"


def main():
    entries = json.load(open(canonical.CATALOG))["entries"]
    edits = json.load(open(canonical.EDITS)) if canonical.EDITS.exists() else {}
    det = json.load(open(canonical.DETERMINISM)) if canonical.DETERMINISM.exists() else {}
    num = json.load(open(canonical.NUMERICS)) if canonical.NUMERICS.exists() else {}
    with tempfile.TemporaryDirectory() as tmp:
        probes, rendered = Path(tmp, "probes"), Path(tmp, "duckdb")
        probes.mkdir()
        sites = {}
        for e in entries:
            sql, _ = canonical.translate(e["sql"], edits.get(e["id"], ()), det.get(e["id"], ()), num.get(e["id"], ()))
            toks = canonical.tokenize(sql)
            sites[e["id"]] = len(canonical.divisions(toks))
            for i, (s, k, j, end) in enumerate(canonical.divisions(toks)):
                a = canonical.text(toks[s:canonical.prev_tok(toks, k) + 1])
                b = canonical.text(toks[j:end + 1])
                probe = canonical.text(toks[:s]) + f"ascii({a}, {b})" + canonical.text(toks[end + 1:])
                (probes / f"{e['id']}_{i:03d}.sql").write_text(probe)
        subprocess.run([str(ROOT / "target/release/dbo-bench"), "render", "--system", "duckdb", "--out", str(rendered),
                        "--queries", str(probes)], check=True, capture_output=True)
        head = (rendered / "schema.sql").read_text() + (rendered / "settings.sql").read_text()
        jobs = sorted(p for p in rendered.glob("q*_*.sql"))
        with ThreadPoolExecutor() as pool:
            found = dict(zip((p.stem for p in jobs),
                             pool.map(lambda p: types(head + "EXPLAIN " + p.read_text().strip().rstrip(";") + ";\n"), jobs)))
    out = {q: [found[f"{q}_{i:03d}"] for i in range(n)] for q, n in sites.items() if n}
    (canonical.QUERIES / "divisions.json").write_text(json.dumps(out, indent=1) + "\n")
    count = lambda k: sum(v.count(k) for v in out.values())
    print(f"{sum(len(v) for v in out.values())} divisions in {len(out)} queries: "
          + ", ".join(f"{count(k)} {k or 'other'}" for k in ("int", "decimal", None)))


if __name__ == "__main__":
    main()
