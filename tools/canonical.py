#!/usr/bin/env python3
"""Build the canonical benchmark queries from the catalog: workload/queries/qNNN.sql.

    python3 tools/canonical.py

Each catalog query's original SQL goes through two kinds of steps, recorded per query in
workload/queries/derivations.json:

- **hard** translations: changes that cannot affect performance, applied to the text for
  every database (`x::t` to `CAST(x AS t)`, `LIMIT n` to `FETCH FIRST n ROWS ONLY`,
  `date_part('f', x)` to `EXTRACT(f FROM x)`, `DATE(x)` to `CAST(x AS DATE)`, a date string
  compared with a column to a `DATE` literal);
- **portability**: a selected bare `t.col` gets `AS col`, the name SQL gives it anyway (some
  databases name it `t.col` after several joins);
- **dialect** placeholders: constructs that databases spell differently, replaced by a
  `{{handler(...)}}` that the runner renders per database (bench/src/dialect.rs); `bool_or`,
  `percentile_cont`, sorted `string_agg`, seconds between timestamps, differences of dates,
  `= ANY(array)` and `COUNT(DISTINCT (a, b))` are replaced last, after the exact text edits and
  the numeric steps below. Which difference becomes an edit, a placeholder or stays a system's
  error: docs/DIALECTS.md;
- **null order**: every sort key without NULLS FIRST/LAST gets the one of the reference
  results (NULLS LAST ascending, NULLS FIRST descending), which the standard leaves to the
  implementation;
- **fetch first**, last: `FETCH FIRST n ROWS ONLY` becomes `{{fetch_first(n)}}`, whose default is
  the same standard clause (a system without it spells it `LIMIT n`); last, because the steps
  before match the clause's text.

Per-query manual edits (exact text replacements with a note) are listed in
workload/queries/edits.json and applied first. Two more sets of exact replacements with a note
are applied to the canonical text at the end:
- determinism fixes (tie-breakers), workload/queries/determinism.json;
- numeric normalization (docs/NUMERICS.md: no rounding, explicit exact arithmetic, FLOOR
  instead of casts of fractions), workload/queries/numerics.json.
Last, two numeric steps give values an exact type: seconds between timestamps
(`epoch_seconds`) and currency conversions (`rate_conversions`) are cast to NUMERIC(18,6).
"""

import json
import re
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
CATALOG = ROOT / "workload" / "catalog.json"
QUERIES = ROOT / "workload" / "queries"
EDITS = QUERIES / "edits.json"
DETERMINISM = QUERIES / "determinism.json"
NUMERICS = QUERIES / "numerics.json"

# keywords that can stand before '(' without being a function name
NOT_FUNCTIONS = {"AND", "OR", "NOT", "IN", "AS", "SELECT", "WHERE", "ON", "WHEN", "THEN", "ELSE",
                 "BY", "FROM", "JOIN", "EXISTS", "CASE", "IS", "BETWEEN", "LIKE", "ILIKE", "ANY",
                 "ALL", "SOME", "UNION", "INTERSECT", "EXCEPT", "WITH", "HAVING", "VALUES",
                 "USING", "LATERAL", "RETURN", "OVER", "FILTER", "GROUP", "WITHIN", "INTERVAL"}



# --- tokenizer ----------------------------------------------------------------------------

TOKEN = re.compile(r"""
    (?P<ws>\s+)
  | (?P<comment>--[^\n]*|/\*.*?\*/)
  | (?P<string>'(?:[^']|'')*')
  | (?P<qident>"(?:[^"]|"")*")
  | (?P<placeholder>\{\{|\}\})
  | (?P<number>\d+(?:\.\d*)?(?:[eE][-+]?\d+)?|\.\d+(?:[eE][-+]?\d+)?)
  | (?P<ident>[A-Za-z_][A-Za-z0-9_$]*)
  | (?P<op>::|->>|->|<=|>=|<>|!=|\|\||[-+*/%<>=(),.;\[\]{}|^~!@#&:?])
""", re.S | re.X)


class Tok:
    __slots__ = ("kind", "text")

    def __init__(self, kind, text):
        self.kind, self.text = kind, text

    def __repr__(self):
        return f"{self.kind}:{self.text!r}"

    def kw(self, *words):
        return self.kind == "ident" and self.text.upper() in words


def tokenize(sql):
    out, pos = [], 0
    while pos < len(sql):
        m = TOKEN.match(sql, pos)
        if not m:
            raise ValueError(f"cannot tokenize at {pos}: {sql[pos:pos + 30]!r}")
        out.append(Tok(m.lastgroup, m.group()))
        pos = m.end()
    return out


def text(toks):
    return "".join(t.text for t in toks)


def match_paren(toks, i):
    """Index of the parenthesis matching toks[i] ('(' forward or ')' backward)."""
    step, open_, close = (1, "(", ")") if toks[i].text == "(" else (-1, ")", "(")
    depth = 0
    while 0 <= i < len(toks):
        if toks[i].kind == "op" and toks[i].text == open_:
            depth += 1
        elif toks[i].kind == "op" and toks[i].text == close:
            depth -= 1
            if depth == 0:
                return i
        i += step
    raise ValueError("unbalanced parentheses")


def split_args(toks):
    """Split tokens at top-level commas."""
    args, depth, cur = [], 0, []
    for t in toks:
        if t.kind == "op" and t.text in "([":
            depth += 1
        elif t.kind == "op" and t.text in ")]":
            depth -= 1
        if depth == 0 and t.kind == "op" and t.text == ",":
            args.append(cur)
            cur = []
        else:
            cur.append(t)
    args.append(cur)
    return args

def prev_tok(toks, i):
    i -= 1
    while i >= 0 and toks[i].kind in ("ws", "comment"):
        i -= 1
    return i


def next_tok(toks, i):
    i += 1
    while i < len(toks) and toks[i].kind in ("ws", "comment"):
        i += 1
    return i


def operand_start(toks, k):
    """Start index of the postfix operand that ends at toks[k] (for `operand::type`)."""
    t = toks[k]
    if t.kind == "op" and t.text == ")":
        m = match_paren(toks, k)
        p = prev_tok(toks, m)
        if p >= 0 and toks[p].kw("GROUP") and toks[prev_tok(toks, p)].kw("WITHIN"):
            return operand_start(toks, prev_tok(toks, prev_tok(toks, p)))
        if p >= 0 and toks[p].kw("FILTER", "OVER"):
            return operand_start(toks, prev_tok(toks, p))
        if p >= 0 and toks[p].kind == "ident" and toks[p].text.upper() not in NOT_FUNCTIONS:
            return dotted_start(toks, p)
        return m
    if t.kw("END"):  # CASE ... END
        depth, i = 0, k
        while i >= 0:
            if toks[i].kw("END"):
                depth += 1
            elif toks[i].kw("CASE"):
                depth -= 1
                if depth == 0:
                    return i
            i -= 1
        raise ValueError("CASE without END")
    if t.kind == "string":
        p = prev_tok(toks, k)  # typed literal: DATE '...', TIMESTAMP '...'
        if p >= 0 and toks[p].kw("DATE", "TIMESTAMP", "INTERVAL", "TIME"):
            return p
        return k
    if t.kind in ("ident", "qident", "number"):
        return dotted_start(toks, k)
    raise ValueError(f"unexpected operand end {t!r}")


def dotted_start(toks, k):
    """Extend an identifier back over `a.b.` prefixes."""
    while k >= 2 and toks[k - 1].kind == "op" and toks[k - 1].text == "." and toks[k - 2].kind in ("ident", "qident"):
        k -= 2
    return k


MULTIWORD = [("DOUBLE", "PRECISION"), ("CHARACTER", "VARYING"), ("TIMESTAMP", "WITH", "TIME", "ZONE"),
             ("TIMESTAMP", "WITHOUT", "TIME", "ZONE"), ("TIME", "WITH", "TIME", "ZONE"),
             ("TIME", "WITHOUT", "TIME", "ZONE")]


def type_end(toks, i):
    """Index after the type name that starts at toks[i]."""
    for words in MULTIWORD:
        j, ok = i, True
        for n, w in enumerate(words):
            if n:
                j = next_tok(toks, j)
            if j >= len(toks) or not toks[j].kw(w):
                ok = False
                break
        if ok:
            i = j
            break
    end = i + 1
    j = next_tok(toks, i)
    if j < len(toks) and toks[j].kind == "op" and toks[j].text == "(":
        end = match_paren(toks, j) + 1
        j = next_tok(toks, end - 1)
    if j + 1 < len(toks) and toks[j].text == "[" and toks[j + 1].text == "]":
        end = j + 2
    return end


def cast_operator(toks):
    """`operand::type` to `CAST(operand AS type)`, left to right (chains nest correctly)."""
    n = 0
    while True:
        i = next((i for i, t in enumerate(toks) if t.kind == "op" and t.text == "::"), None)
        if i is None:
            return toks, n
        k = prev_tok(toks, i)
        s = operand_start(toks, k)
        ts = next_tok(toks, i)
        te = type_end(toks, ts)
        new = f"CAST({text(toks[s:k + 1])} AS {text(toks[ts:te])})"
        toks = toks[:s] + [Tok("raw", new)] + toks[te:]
        toks = tokenize(text(toks))
        n += 1


def limit_fetch(toks):
    """`LIMIT n` to `FETCH FIRST n ROWS ONLY`."""
    n = 0
    for i, t in enumerate(toks):
        if t.kw("LIMIT"):
            j = next_tok(toks, i)
            if j < len(toks) and toks[j].kind == "number":
                toks[i] = Tok("raw", "FETCH FIRST")
                toks[j] = Tok("raw", f"{toks[j].text} ROWS ONLY")
                n += 1
    return toks, n


def date_part_extract(toks):
    """`date_part('field', x)` to `EXTRACT(field FROM x)`."""
    n = 0
    while True:
        i = next((i for i, t in enumerate(toks) if t.kw("DATE_PART") and toks[next_tok(toks, i)].text == "("), None)
        if i is None:
            return toks, n
        lp = next_tok(toks, i)
        rp = match_paren(toks, lp)
        field, rest = split_args(toks[lp + 1:rp])[0], split_args(toks[lp + 1:rp])[1:]
        f = text(field).strip()
        if not re.fullmatch(r"'[a-zA-Z]+'", f) or len(rest) != 1:
            raise ValueError(f"unexpected date_part arguments {text(toks[lp:rp + 1])}")
        new = f"EXTRACT({f[1:-1].upper()} FROM {text(rest[0]).strip()})"
        toks = tokenize(text(toks[:i]) + new + text(toks[rp + 1:]))
        n += 1


def date_function(toks):
    """`DATE(x)` to `CAST(x AS DATE)`: the function is PostgreSQL's, the cast is standard."""
    n = 0
    while True:
        sites = call_sites(toks, "date")
        if not sites:
            return toks, n
        i, lp, rp = sites[0]
        args = split_args(toks[lp + 1:rp])
        if len(args) != 1:
            raise ValueError(f"unexpected date arguments {text(toks[lp:rp + 1])}")
        toks = tokenize(text(toks[:i]) + f"CAST({text(args[0]).strip()} AS DATE)" + text(toks[rp + 1:]))
        n += 1


DATE_STR = re.compile(r"'\d{4}-\d\d-\d\d'")
COMPARE = {"=", "<", ">", "<=", ">=", "<>", "!="}


def date_literals(toks):
    """A date string compared with something (`>= '2025-01-01'`, `BETWEEN '...' AND '...'`)
    becomes a DATE literal."""
    n = 0
    for i, t in enumerate(toks):
        if t.kind != "string" or not DATE_STR.fullmatch(t.text):
            continue
        p = prev_tok(toks, i)
        if p < 0 or toks[p].kw("DATE", "TIMESTAMP"):
            continue
        comparing = (toks[p].kind == "op" and toks[p].text in COMPARE) or toks[p].kw("BETWEEN")
        if toks[p].kw("AND"):  # second bound of BETWEEN
            q = prev_tok(toks, p)
            comparing = q >= 0 and toks[q].kind == "string" and toks[prev_tok(toks, q)].kw("BETWEEN", "DATE")
        if comparing:
            toks[i] = Tok("raw", f"DATE {t.text}")
            n += 1
    return toks, n


def call_sites(toks, name):
    """(start, lparen, rparen) of every call of function `name`."""
    out = []
    for i, t in enumerate(toks):
        if t.kw(name.upper()):
            lp = next_tok(toks, i)
            if lp < len(toks) and toks[lp].text == "(":
                p = prev_tok(toks, i)
                if p >= 0 and ((toks[p].kind == "op" and toks[p].text == ".") or toks[p].kind == "placeholder"):
                    continue
                out.append((i, lp, match_paren(toks, lp)))
    return out


def placeholder_strftime(toks):
    n = 0
    while True:
        sites = [s for s in call_sites(toks, "strftime")]
        if not sites:
            return toks, n
        i, lp, rp = sites[0]
        args = [text(a).strip() for a in split_args(toks[lp + 1:rp])]
        if len(args) != 2 or args[1] != "'%Y-%m'":
            raise ValueError(f"unsupported strftime {text(toks[i:rp + 1])}")
        toks = tokenize(text(toks[:i]) + "{{year_month(" + args[0] + ")}}" + text(toks[rp + 1:]))
        n += 1


def placeholder_date_diff(toks):
    n = 0
    while True:
        sites = call_sites(toks, "date_diff")
        if not sites:
            return toks, n
        i, lp, rp = sites[0]
        args = [text(a).strip() for a in split_args(toks[lp + 1:rp])]
        if len(args) != 3 or args[0].lower() != "'day'":
            raise ValueError(f"unsupported date_diff {text(toks[i:rp + 1])}")
        toks = tokenize(text(toks[:i]) + "{{date_diff_days(" + args[1] + ", " + args[2] + ")}}" + text(toks[rp + 1:]))
        n += 1


def placeholder_date_trunc(toks):
    """date_trunc('unit', x) -> {{date_trunc('unit', x)}}: not in the standard, and of the reference dialects only
    PostgreSQL has it (with a timestamp as its result)."""
    n = 0
    while True:
        sites = call_sites(toks, "date_trunc")
        if not sites:
            return toks, n
        i, lp, rp = sites[0]
        args = [text(a).strip() for a in split_args(toks[lp + 1:rp])]
        if len(args) != 2 or args[0].lower() not in ("'hour'", "'month'", "'quarter'"):
            raise ValueError(f"unsupported date_trunc {text(toks[i:rp + 1])}")
        toks = tokenize(text(toks[:i]) + "{{date_trunc(" + args[0].lower() + ", " + args[1] + ")}}" + text(toks[rp + 1:]))
        n += 1


def placeholder_count_distinct_over(toks):
    n = 0
    for i, lp, rp in call_sites(toks, "count"):
        inner = [t for t in toks[lp + 1:rp] if t.kind not in ("ws", "comment")]
        o = next_tok(toks, rp)
        if not inner or not inner[0].kw("DISTINCT") or o >= len(toks) or not toks[o].kw("OVER"):
            continue
        wl = next_tok(toks, o)
        wr = match_paren(toks, wl)
        x = text(toks[lp + 1:rp]).strip()[len("DISTINCT"):].strip()
        new = "{{count_distinct_over(" + x + ", " + text(toks[wl:wr + 1]) + ")}}"
        return placeholder_count_distinct_over(tokenize(text(toks[:i]) + new + text(toks[wr + 1:])))[0], n + 1
    return toks, n


def placeholder_bool_or(toks):
    """BOOL_OR(x) -> {{bool_or(x)}}."""
    n = 0
    while True:
        sites = call_sites(toks, "bool_or")
        if not sites:
            return toks, n
        i, lp, rp = sites[0]
        toks = tokenize(text(toks[:i]) + "{{bool_or(" + text(toks[lp + 1:rp]).strip() + ")}}" + text(toks[rp + 1:]))
        n += 1


def placeholder_percentile_cont(toks):
    """PERCENTILE_CONT(p) WITHIN GROUP (ORDER BY x) -> {{percentile_cont(p, x)}}; with FILTER (WHERE c) after it,
    {{percentile_cont_filter(p, x, c)}} (some systems cannot filter an ordered-set aggregate)."""
    n = 0
    while True:
        sites = call_sites(toks, "percentile_cont")
        if not sites:
            return toks, n
        i, lp, rp = sites[0]
        w = next_tok(toks, rp)
        g = next_tok(toks, w)
        gl = next_tok(toks, g)
        if not (toks[w].kw("WITHIN") and toks[g].kw("GROUP") and toks[gl].text == "("):
            raise ValueError(f"unsupported percentile_cont {text(toks[i:rp + 1])}")
        gr = match_paren(toks, gl)
        inner = text(toks[gl + 1:gr]).strip()
        m = re.fullmatch(r"(?is)order\s+by\s+(.*?)(\s+asc)?", inner)
        if not m or re.search(r"(?i)\s(desc|nulls)\b", inner):
            raise ValueError(f"unsupported percentile_cont ordering {inner!r}")
        p = text(toks[lp + 1:rp]).strip()
        x = m.group(1).strip()
        fi = next_tok(toks, gr)
        if fi < len(toks) and toks[fi].kw("FILTER"):
            fl = next_tok(toks, fi)
            fr = match_paren(toks, fl)
            cond = re.fullmatch(r"(?is)\s*where\s+(.*?)\s*", text(toks[fl + 1:fr]))
            if not cond:
                raise ValueError(f"unsupported FILTER {text(toks[fi:fr + 1])}")
            new, end = "{{percentile_cont_filter(" + p + ", " + x + ", " + cond.group(1) + ")}}", fr
        else:
            new, end = "{{percentile_cont(" + p + ", " + x + ")}}", gr
        toks = tokenize(text(toks[:i]) + new + text(toks[end + 1:]))
        n += 1


def explicit_column_aliases(toks):
    """A select-list item that is a bare qualified column `t.col` gets `AS col`: its name by the SQL standard,
    made explicit (after several joins, ClickHouse names it `t.col`, and a later reference to `col` fails)."""
    n, i = 0, 0
    while i < len(toks):
        if toks[i].kw("SELECT"):
            # the select list: up to FROM, or the end of the enclosing parentheses or statement, at this depth
            j, depth = next_tok(toks, i), 0
            if j < len(toks) and toks[j].kw("DISTINCT", "ALL"):
                j = next_tok(toks, j)
            start = j
            while j < len(toks):
                t = toks[j]
                if t.kind == "op" and t.text == "(":
                    depth += 1
                elif t.kind == "op" and t.text == ")":
                    if depth == 0:
                        break
                    depth -= 1
                elif depth == 0 and (t.kw("FROM", "UNION", "INTERSECT", "EXCEPT", "WHERE") or (t.kind == "op" and t.text == ";")):
                    break
                j += 1
            items, out = split_args(toks[start:j]), []
            for k, item in enumerate(items):
                core = [t for t in item if t.kind not in ("ws", "comment")]
                if len(core) == 3 and core[0].kind == "ident" and core[1].text == "." and core[2].kind == "ident":
                    # keep the item's surrounding space: the alias goes right after the column
                    last = max(x for x, t in enumerate(item) if t is core[2])
                    item = item[:last + 1] + [Tok("ws", " "), Tok("ident", "AS"), Tok("ws", " "), Tok("ident", core[2].text)] + item[last + 1:]
                    n += 1
                out += item + ([Tok("op", ",")] if k + 1 < len(items) else [])
            toks = toks[:start] + out + toks[j:]
            i = start + len(out)
        else:
            i += 1
    return toks, n


def placeholder_string_agg(toks):
    """STRING_AGG([DISTINCT] x, sep ORDER BY x) -> {{string_agg_sorted(x, sep)}} or {{string_agg_distinct_sorted(x, sep)}}."""
    n, skip = 0, 0
    while True:
        sites = call_sites(toks, "string_agg")[skip:]
        if not sites:
            return toks, n
        i, lp, rp = sites[0]
        m = re.fullmatch(r"(?is)\s*(distinct\s+)?(.*?)\s+order\s+by\s+(.*?)\s*", text(toks[lp + 1:rp]))
        args = split_args(tokenize(m.group(2))) if m else []
        if not m or len(args) != 2 or text(args[0]).strip() != m.group(3).strip():
            skip += 1  # without an ORDER BY, or ordered by something else: left as it is
            continue
        name = "string_agg_distinct_sorted" if m.group(1) else "string_agg_sorted"
        toks = tokenize(text(toks[:i]) + "{{" + name + "(" + text(args[0]).strip() + ", " + text(args[1]).strip() + ")}}" + text(toks[rp + 1:]))
        n += 1


def cast_parts(toks, i):
    """For CAST at toks[i]: (lparen, the AS token, rparen), the AS at the top level of the parentheses."""
    lp = next_tok(toks, i)
    if lp >= len(toks) or toks[lp].text != "(":
        return None
    rp, depth, as_ = match_paren(toks, lp), 0, None
    for k in range(lp + 1, rp):
        if toks[k].text == "(":
            depth += 1
        elif toks[k].text == ")":
            depth -= 1
        elif depth == 0 and toks[k].kw("AS"):
            as_ = k
    return (lp, as_, rp) if as_ else None


def top_level(toks, a, b, ops):
    """Indices of the operators in `ops` at the top level of toks[a:b]."""
    out, depth = [], 0
    for k in range(a, b):
        if toks[k].text == "(":
            depth += 1
        elif toks[k].text == ")":
            depth -= 1
        elif depth == 0 and toks[k].kind == "op" and toks[k].text in ops:
            out.append(k)
    return out


def placeholder_seconds_between(toks):
    """CAST(EXTRACT(EPOCH FROM (b - a)) AS NUMERIC(18,6)) -> {{seconds_between(a, b)}}: the exact seconds from a
    to b (docs/NUMERICS.md), which systems spell differently."""
    n, k = 0, 0
    while k < len(toks):
        parts = cast_parts(toks, k) if toks[k].kw("CAST") else None
        if parts and re.fullmatch(r"(?is)\s*numeric\s*\(\s*18\s*,\s*6\s*\)\s*", text(toks[parts[1] + 1:parts[2]])):
            lp, as_, rp = parts
            e = next_tok(toks, lp)
            m = re.fullmatch(r"(?is)\s*extract\s*\(\s*epoch\s+from\s*\((.*)\)\s*\)\s*", text(toks[e:as_]))
            if m:
                inner = tokenize(m.group(1))
                minus = top_level(inner, 0, len(inner), {"-", "+"})
                if len(minus) == 1 and inner[minus[0]].text == "-":
                    b, a = text(inner[:minus[0]]).strip(), text(inner[minus[0] + 1:]).strip()
                    toks = tokenize(text(toks[:k]) + "{{seconds_between(" + a + ", " + b + ")}}" + text(toks[rp + 1:]))
                    n += 1
        k += 1
    return toks, n


def placeholder_date_minus(toks):
    """CAST(x AS DATE) - CAST(y AS DATE) -> {{date_diff_days(y, x)}}, the days from y to x (in some systems the
    difference of two dates is an interval). Only where no stronger operator touches either side."""
    n, k = 0, 0
    while k < len(toks):
        first = cast_parts(toks, k) if toks[k].kw("CAST") else None
        if first and re.fullmatch(r"(?is)\s*date\s*", text(toks[first[1] + 1:first[2]])):
            m_ = next_tok(toks, first[2])
            c2 = next_tok(toks, m_)
            second = cast_parts(toks, c2) if m_ < len(toks) and toks[m_].text == "-" and c2 < len(toks) and toks[c2].kw("CAST") else None
            if second and re.fullmatch(r"(?is)\s*date\s*", text(toks[second[1] + 1:second[2]])):
                before, after = prev_tok(toks, k), next_tok(toks, second[2])
                if not (before >= 0 and toks[before].text in ("*", "/", "%", "-", "+", "::")) and not (after < len(toks) and toks[after].text in ("*", "/", "%", "::")):
                    x = text(toks[first[0] + 1:first[1]]).strip()
                    y = text(toks[second[0] + 1:second[1]]).strip()
                    s, e = k, second[2]
                    call = prev_tok(toks, before) if before >= 0 else -1
                    if (before >= 0 and toks[before].text == "(" and after < len(toks) and toks[after].text == ")"
                            and not (call >= 0 and toks[call].kind in ("ident", "qident", "placeholder"))):
                        s, e = before, after  # parentheses around it (not a call's) are the default's own
                    toks = tokenize(text(toks[:s]) + "{{date_diff_days(" + y + ", " + x + ")}}" + text(toks[e + 1:]))
                    n += 1
        k += 1
    return toks, n


def placeholder_equals_any(toks):
    """x = ANY(<array column>) -> {{equals_any(x, column)}} (not ANY over a subquery): some systems store the
    arrays as text and turn them back into arrays to search them."""
    n, k = 0, 0
    while k < len(toks):
        if toks[k].kw("ANY"):
            lp, eq = next_tok(toks, k), prev_tok(toks, k)
            if lp < len(toks) and toks[lp].text == "(" and eq >= 0 and toks[eq].text == "=":
                rp = match_paren(toks, lp)
                col = text(toks[lp + 1:rp]).strip()
                if re.fullmatch(r"(?:\w+\.)?\w+", col) and not re.match(r"(?i)select\b", col):
                    s = operand_start(toks, prev_tok(toks, eq))
                    x = text(toks[s:eq]).strip()
                    toks = tokenize(text(toks[:s]) + "{{equals_any(" + x + ", " + col + ")}}" + text(toks[rp + 1:]))
                    n += 1
        k += 1
    return toks, n


def placeholder_count_distinct_pair(toks):
    """COUNT(DISTINCT (a, b)) -> {{count_distinct_pair(a, b)}}: distinct pairs, counted as a row value, which not
    every system has."""
    n = 0
    while True:
        sites = [s for s in call_sites(toks, "count")
                 if re.fullmatch(r"(?is)\s*distinct\s*\(([^()]*),([^()]*)\)\s*", text(toks[s[1] + 1:s[2]]))]
        if not sites:
            return toks, n
        i, lp, rp = sites[0]
        m = re.fullmatch(r"(?is)\s*distinct\s*\(([^()]*),([^()]*)\)\s*", text(toks[lp + 1:rp]))
        toks = tokenize(text(toks[:i]) + "{{count_distinct_pair(" + m.group(1).strip() + ", " + m.group(2).strip() + ")}}" + text(toks[rp + 1:]))
        n += 1


# Spellings that differ between databases and are made placeholders last, after the exact text
# edits (determinism, numerics), which were written against the original spelling.
DIALECT_LAST = [("bool_or", placeholder_bool_or), ("percentile_cont", placeholder_percentile_cont),
                ("string_agg", placeholder_string_agg),
                ("seconds_between", placeholder_seconds_between), ("date_diff_days", placeholder_date_minus),
                ("equals_any", placeholder_equals_any), ("count_distinct_pair", placeholder_count_distinct_pair),
                ("date_trunc", placeholder_date_trunc)]


# --- ORDER BY tie-breakers (determinism) ------------------------------------------------

STOP_ORDER = {"FETCH", "LIMIT", "OFFSET", "UNION", "INTERSECT", "EXCEPT"}


FRAME_UNITS = {"ROWS", "RANGE", "GROUPS"}


def null_order(toks):
    """Every sort key without NULLS FIRST or NULLS LAST gets the one of the reference results:
    NULLS LAST ascending, NULLS FIRST descending. The standard leaves the default to the
    implementation; this covers query, window and aggregate ORDER BYs."""
    inserts = []
    for i, t in enumerate(toks):
        if not t.kw("ORDER"):
            continue
        b = next_tok(toks, i)
        if b >= len(toks) or not toks[b].kw("BY"):
            continue
        keys, start, depth, j = [], next_tok(toks, b), 0, next_tok(toks, b)
        while j < len(toks):
            tj = toks[j]
            if tj.kind == "op" and tj.text in "([":
                depth += 1
            elif tj.kind == "op" and tj.text in ")]":
                if depth == 0:
                    break
                depth -= 1
            elif depth == 0 and ((tj.kind == "op" and tj.text == ";") or tj.kw(*STOP_ORDER) or tj.kw(*FRAME_UNITS)):
                break
            elif depth == 0 and tj.kind == "op" and tj.text == ",":
                keys.append((start, j))
                start = next_tok(toks, j)
            j += 1
        keys.append((start, j))
        for a, e in keys:
            while e > a and toks[e - 1].kind in ("ws", "comment"):
                e -= 1
            if e <= a:
                continue
            level, top = 0, []
            for k in range(a, e):
                if toks[k].kind == "op" and toks[k].text in "([":
                    level += 1
                elif toks[k].kind == "op" and toks[k].text in ")]":
                    level -= 1
                elif level == 0:
                    top.append(toks[k])
            if any(x.kw("NULLS") for x in top):
                continue
            inserts.append((e, " NULLS FIRST" if toks[e - 1].kw("DESC") else " NULLS LAST"))
    for pos, ins in sorted(inserts, reverse=True):
        toks = toks[:pos] + [Tok("raw", ins)] + toks[pos:]
    return toks, len(inserts)


HARD = [("cast", cast_operator), ("fetch_first", limit_fetch), ("extract", date_part_extract),
        ("date_cast", date_function), ("date_literal", date_literals)]
DIALECT = [("year_month", placeholder_strftime), ("date_diff_days", placeholder_date_diff),
           ("count_distinct_over", placeholder_count_distinct_over)]


def apply_determinism(sql, edits):
    """Exact replacements on the canonical text (determinism and numeric edits); each `from`
    must occur exactly once."""
    for ed in edits:
        if sql.count(ed["from"]) != 1:
            raise ValueError(f"edit must match exactly once: {ed['from']!r}")
        sql = sql.replace(ed["from"], ed["to"])
    return sql


def epoch_seconds(sql):
    """`EXTRACT(EPOCH FROM (b - a))` to `CAST(EXTRACT(EPOCH FROM (b - a)) AS NUMERIC(18,6))`
    (docs/NUMERICS.md): the seconds between two timestamps get an explicit type in every
    engine (a double in DuckDB, an unconstrained or numeric(23,6) numeric elsewhere). Scale 6
    is exact for microsecond timestamps, so the cast never rounds."""
    toks = tokenize(sql)
    n = 0
    for i in range(len(toks) - 1, -1, -1):
        if not toks[i].kw("EXTRACT"):
            continue
        lp = next_tok(toks, i)
        if lp >= len(toks) or toks[lp].text != "(":
            continue
        rp = match_paren(toks, lp)
        f = next_tok(toks, lp)
        if not toks[f].kw("EPOCH"):
            continue
        fr = next_tok(toks, f)
        arg = text(toks[fr + 1:rp]).strip()
        p = prev_tok(toks, i)
        if p >= 0 and toks[p].text == "(" and toks[prev_tok(toks, p)].kw("CAST"):
            continue  # already cast
        if not (arg.startswith("(") and match_paren(tokenize(arg), 0) == len(tokenize(arg)) - 1):
            arg = f"({arg})"
        toks = toks[:i] + [Tok("raw", f"CAST(EXTRACT(EPOCH FROM {arg}) AS NUMERIC(18,6))")] + toks[rp + 1:]
        n += 1
    return text(toks), n


# columns that hold exchange rates (exchange_rates.rate and the queries' aliases of it); the
# schema's only other `rate` column, tax_rates.rate, is used by no query
RATE_COLUMNS = {"rate", "eur_rate", "fx_rate"}


def rate_divisor_end(toks, j):
    """Index of the last token of a divisor starting at toks[j] that is an exchange rate
    (`er.rate`, or `NULLIF(er.rate, ...)` / `COALESCE(er.rate, ...)`), else None."""
    def rate_column(k):
        if k >= len(toks) or toks[k].kind not in ("ident", "qident"):
            return None
        while k + 2 < len(toks) and toks[k + 1].text == "." and toks[k + 2].kind in ("ident", "qident"):
            k += 2
        return k if toks[k].text.lower() in RATE_COLUMNS else None
    if j < len(toks) and toks[j].kw("NULLIF", "COALESCE"):
        lp = next_tok(toks, j)
        if lp < len(toks) and toks[lp].text == "(":
            e = rate_column(next_tok(toks, lp))
            if e is not None and toks[next_tok(toks, e)].text == ",":
                return match_paren(toks, lp)
        return None
    return rate_column(j)


def term_start(toks, k):
    """Start of the multiplicative term that ends with the operator at toks[k] (`*` and `/`
    associate to the left, so `a * b / r` divides `a * b`)."""
    s = operand_start(toks, prev_tok(toks, k))
    while True:
        p = prev_tok(toks, s)
        if p >= 0 and toks[p].kind == "op" and toks[p].text in ("*", "/"):
            s = operand_start(toks, prev_tok(toks, p))
        else:
            return s


def rate_conversions(sql):
    """`x / er.rate` to `CAST(x / er.rate AS NUMERIC(18,6))` (docs/NUMERICS.md): a currency
    conversion gets an exact type in every engine. DuckDB divides decimals in double
    precision, and a CASE with one converted branch then turns its exact branches (EUR
    amounts) into doubles too; exact ties then sort by noise."""
    n = done = 0
    while True:
        toks = tokenize(sql)
        sites = [(k, e) for k, t in enumerate(toks) if t.kind == "op" and t.text == "/"
                 for e in [rate_divisor_end(toks, next_tok(toks, k))] if e is not None]
        if done >= len(sites):
            return sql, n
        k, e = sites[done]
        done += 1
        s = term_start(toks, k)
        p = prev_tok(toks, s)
        if p >= 1 and toks[p].text == "(" and toks[prev_tok(toks, p)].kw("CAST") and toks[next_tok(toks, e)].kw("AS"):
            continue  # already cast
        sql = text(toks[:s]) + "CAST(" + text(toks[s:e + 1]) + " AS NUMERIC(18,6))" + text(toks[e + 1:])
        n += 1


def translate(sql, edits=(), determinism=(), numerics=()):
    """Canonical text and the steps applied."""
    steps = []
    for ed in edits:
        if ed["from"] not in sql:
            raise ValueError(f"edit not found: {ed['from']!r}")
        sql = sql.replace(ed["from"], ed["to"])
        steps.append({"kind": "manual", "step": "edit", "count": 1, "note": ed["note"]})
    toks = tokenize(sql.strip().rstrip(";").rstrip())
    for name, fn in HARD:
        toks, n = fn(toks)
        if n:
            steps.append({"kind": "hard", "step": name, "count": n})
    for name, fn in DIALECT:
        toks, n = fn(toks)
        if n:
            steps.append({"kind": "dialect", "step": name, "count": n})
    out = text(toks) + "\n"
    if determinism:
        out = apply_determinism(out, determinism)
        steps += [{"kind": "determinism", "step": "edit", "count": 1, "note": d["note"]} for d in determinism]
    if numerics:
        out = apply_determinism(out, numerics)
        steps += [{"kind": "numeric", "step": "edit", "count": 1, "note": d["note"]} for d in numerics]
    out, n = epoch_seconds(out)
    if n:
        steps.append({"kind": "numeric", "step": "epoch_seconds", "count": n,
                      "note": "docs/NUMERICS.md: EXTRACT(EPOCH FROM (b - a)) cast to NUMERIC(18,6)"})
    out, n = rate_conversions(out)
    if n:
        steps.append({"kind": "numeric", "step": "rate_conversion", "count": n,
                      "note": "docs/NUMERICS.md: x / exchange rate cast to NUMERIC(18,6)"})
    toks = tokenize(out.rstrip("\n"))
    toks, n = explicit_column_aliases(toks)
    if n:
        steps.append({"kind": "portability", "step": "explicit_column_alias", "count": n,
                      "note": "a selected t.col gets AS col, its standard name made explicit"})
    for name, fn in DIALECT_LAST:
        toks, n = fn(toks)
        if n:
            steps.append({"kind": "dialect", "step": name, "count": n})
    toks, n = null_order(toks)
    if n:
        steps.append({"kind": "determinism", "step": "null_order", "count": n,
                      "note": "the standard leaves the place of NULLs in a sort to the implementation: "
                              "NULLS LAST ascending, NULLS FIRST descending, as in the reference results"})
    out, n = re.subn(r"(?i)\bFETCH\s+FIRST\s+(\d+)\s+ROWS?\s+ONLY\b", r"{{fetch_first(\1)}}", text(toks))
    if n:
        steps.append({"kind": "dialect", "step": "fetch_first", "count": n})
    return out + "\n", steps


def main():
    entries = json.load(open(CATALOG))["entries"]
    edits = json.load(open(EDITS)) if EDITS.exists() else {}
    det = json.load(open(DETERMINISM)) if DETERMINISM.exists() else {}
    num = json.load(open(NUMERICS)) if NUMERICS.exists() else {}
    QUERIES.mkdir(parents=True, exist_ok=True)
    derivations = {}
    for e in entries:
        sql, steps = translate(e["sql"], edits.get(e["id"], ()),
                               det.get(e["id"], ()), num.get(e["id"], ()))
        (QUERIES / f"{e['id']}.sql").write_text(sql)
        derivations[e["id"]] = steps
    (QUERIES / "derivations.json").write_text(json.dumps(derivations, indent=1) + "\n")
    count = lambda k: sum(1 for s in derivations.values() if any(x["kind"] == k for x in s))
    print(f"wrote {len(entries)} queries to {QUERIES.relative_to(ROOT)}: "
          f"{count('hard')} with hard translations, {count('dialect')} with dialect placeholders, "
          f"{count('numeric')} with numeric normalization")


if __name__ == "__main__":
    main()
