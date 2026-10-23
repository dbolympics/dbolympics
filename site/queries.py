"""Build the query pages: where every benchmark query came from.

    python3 queries.py            # out/queries/index.html and out/queries/qNNN.html
    python3 queries.py --raw      # also copy the role-play archive to out/raw/, for the "everything" links

Reads workload/catalog.json, workload/queries/ and runs/. Every page is static HTML in the start page's
design (style.css); the only script on a page is the tooltip and the arrow keys.
"""
import difflib, html, json, math, os, re, shutil, sys

import build  # the start page's data, marks and logo

HERE = os.path.dirname(os.path.abspath(__file__))  # site/: the scripts, templates, stylesheet and fonts
ROOT = os.path.dirname(HERE)                         # the repository
SITE = os.path.join(HERE, "out")                      # everything built; not checked in
OUT = os.path.join(SITE, "queries")
E = html.escape

catalog = json.load(open(os.path.join(ROOT, "workload", "catalog.json")))
RUN = catalog["runs"][0]
# The archive: runs/ holds the run's files (and its README.md); they are named as in the run, run6/...
RUNS = os.path.join(ROOT, "runs")
NAMES_IN_ARCHIVE = {f"{RUN}/{os.path.relpath(os.path.join(d, f), RUNS)}" for d, _, fs in os.walk(RUNS) for f in fs} - {f"{RUN}/README.md"}
derivations = json.load(open(os.path.join(ROOT, "workload", "queries", "derivations.json")))


# Personal data of whoever ran the role play, which Claude Code put into the transcripts: replaced in the archive
# by a visible marker when it was archived (tools/archive_run.py). The markers are counted for out/raw/REDACTIONS.md.
REDACTED = {what: 0 for what in ("e-mail address", "user name", "per-user temporary folder")}


def rendered_texts():
    """{system: {query: text}}: each query as the runner renders it for each system, placeholders marked."""
    import subprocess, tempfile
    out = {}
    # a variant (base = ... in its system file) gets its base's text
    own = lambda n: "base" not in build.tomllib.load(open(os.path.join(ROOT, "systems", n, "system.toml"), "rb"))
    systems = [n for n in build.NAMES if own(n) and any(n in c["systems"] for c in build.CONFIGS)]
    with tempfile.TemporaryDirectory() as tmp:
        for n in systems:
            d = os.path.join(tmp, n)
            subprocess.run([os.path.join(ROOT, "target", "release", "dbo-bench"), "render", "--system", n, "--out", d, "--mark"],
                           check=True, capture_output=True)
            out[n] = {f[:-4]: open(os.path.join(d, f)).read() for f in os.listdir(d) if re.fullmatch(r"q\d+\.sql", f)}
    return out


def read(path):
    """A file of the archive by its full path (run6/...), or None."""
    return open(os.path.join(RUNS, path.split("/", 1)[1])).read() if path in NAMES_IN_ARCHIVE else None


personas = json.loads(read(f"{RUN}/personas.json"))
MANAGERS = {m["id"]: m for m in personas["managers"]}
ANALYST_STYLE = {a["name"]: a["style"] for a in personas["analysts"]}
ENGINEER_STYLE = {e["name"]: e["style"] for e in personas["engineers"]}
TEAM_ORDER = [m["id"] for m in personas["managers"]]
RUN_CONFIG = json.loads(read(f"{RUN}/run.json"))
NIGHTS, WEEKS = int(RUN_CONFIG["nights"]), int(RUN_CONFIG["weeks"])
EVENT_CHANCE = float(RUN_CONFIG["situations"])  # chance per week that a business event lands on a team without one
EVENT_POOL = json.load(open(os.path.join(ROOT, "roleplay", "situations.json")))["situations"]

# ---------------------------------------------------------------------------------------------------------------
# Text: a little Markdown (what the agents write), SQL highlighting, line diffs


def inline(s):
    s = E(s, quote=False)
    s = re.sub(r"`([^`]+)`", r"<code>\1</code>", s)
    s = re.sub(r"\*\*(.+?)\*\*", r"<b>\1</b>", s)
    s = re.sub(r"(?<![*\w])\*(?!\s)(.+?)(?<!\s)\*(?![*\w])", r"<i>\1</i>", s)
    return s


def md(text):
    """Paragraphs, headings, bullet and numbered lists, bold, italic, code. A list goes on across blank lines between
    its items (a "loose" list, as Markdown has it); a numbered one starts at its first item's number."""
    out, para, items, kind, start = [], [], [], None, 1
    gap = False  # a blank line since the last list item: the list ends unless the next line continues it

    def flush():
        nonlocal para, items, kind, start, gap
        if para:
            out.append(f"<p>{inline(' '.join(para))}</p>")
        if items:
            attr = f' start="{start}"' if kind == "ol" and start != 1 else ""
            out.append(f"<{kind}{attr}>" + "".join(f"<li>{inline(i)}</li>" for i in items) + f"</{kind}>")
        para, items, kind, start, gap = [], [], None, 1, False

    for line in (text or "").splitlines():
        s = line.strip()
        m_h = re.match(r"(#{1,4})\s+(.*)", s)
        m_ul = re.match(r"[-*•]\s+(.*)", s)
        m_ol = re.match(r"(\d+)[.)]\s+(.*)", s)
        if not s:
            if items:
                gap = True
            else:
                flush()
        elif m_h:
            flush()
            out.append(f"<h4>{inline(m_h.group(2))}</h4>")
        elif m_ul or m_ol:
            k = "ul" if m_ul else "ol"
            if para or (kind and kind != k):
                flush()
            if not items and m_ol:
                start = int(m_ol.group(1))
            kind, gap = k, False
            items.append(m_ul.group(1) if m_ul else m_ol.group(2))
        elif items and line.startswith((" ", "\t")):
            items[-1] += " " + s
            gap = False
        else:
            if items:
                flush()
            para.append(s)
    flush()
    return "\n".join(out)


SQL_KW = set(("select from where join left right full outer inner cross on using group by order having limit offset as and or "
              "not in is null case when then else end with recursive distinct all union intersect except over partition rows "
              "range between unbounded preceding following current row filter within asc desc nulls first last like ilike "
              "exists any some date timestamp interval cast true false lateral values extract epoch fetch only").split())
SQL_RE = re.compile(r"(--[^\n]*)|('(?:[^']|'')*')|(\{\{|\}\})|\b(\d+(?:\.\d+)?)\b|([A-Za-z_][A-Za-z0-9_]*)(\s*\()?")


def sql_hl(src):
    out, last = [], 0
    for m in SQL_RE.finditer(src):
        out.append(E(src[last:m.start()], quote=False))
        last = m.end()
        com, s, brace, num, word, paren = m.groups()
        if com: out.append(f'<span class="com">{E(com, quote=False)}</span>')
        elif s: out.append(f'<span class="str">{E(s, quote=False)}</span>')
        elif brace: out.append(f'<span class="com">{brace}</span>')
        elif num: out.append(f'<span class="num">{num}</span>')
        elif word.lower() in SQL_KW: out.append(f'<span class="kw">{word}</span>{paren or ""}')
        elif paren: out.append(f'<span class="fn">{word}</span>{paren}')
        else: out.append(word)
    out.append(E(src[last:], quote=False))
    return "".join(out)


def sql_block(sql, cls=""):
    return f'<pre class="sql {cls}">{sql_hl(sql.strip())}</pre>'


def marked_sql(src):
    """A rendered query with its placeholders (/*{name*/ ... /*}*/) highlighted."""
    h = sql_hl(src.strip())
    h = re.sub(r"/\*\{(\w+)\*/", lambda m: f'<mark class="ph" title="{m.group(1)}">', h)
    return h.replace("/*}*/", "</mark>")


def diff_block(a, b):
    """The lines of b, with what changed from a marked: added lines and the removed ones in between."""
    a, b = a.strip().splitlines(), b.strip().splitlines()
    out = []
    for tag, i1, i2, j1, j2 in difflib.SequenceMatcher(None, a, b, autojunk=False).get_opcodes():
        if tag == "equal":
            out += [f'<span class="ln">{sql_hl(l)}</span>' for l in b[j1:j2]]
        else:
            out += [f'<span class="ln del">{E(l, quote=False)}</span>' for l in a[i1:i2]]
            out += [f'<span class="ln add">{sql_hl(l)}</span>' for l in b[j1:j2]]
    changed = sum(1 for t in difflib.SequenceMatcher(None, a, b, autojunk=False).get_opcodes() if t[0] != "equal")
    return f'<pre class="sql diff">{"".join(out)}</pre>', changed


# ---------------------------------------------------------------------------------------------------------------
# The archive: tracks (one per team), and one record per query

def split_reports(text):
    out = {}
    for m in re.finditer(r"=== Report (\d+): .*? ===\n(.*?)(?=\n=== Report \d+: |\Z)", text or "", re.S):
        lines = [l for l in m.group(2).strip().splitlines() if not l.startswith(("Engineer's note:", "REPORT:", "QUESTION:"))]
        out[int(m.group(1))] = "\n".join(lines).strip()
    return out


def track(team):
    t = {"situation": json.loads(read(f"{RUN}/{team}/situation.json") or "null"), "weeks": {}}
    for w in range(1, WEEKS + 1):
        note = read(f"{RUN}/{team}/week{w}-manager-note.md")
        if note is None:
            continue
        coowners = []
        for p in sorted(n for n in NAMES_IN_ARCHIVE if n.startswith(f"{RUN}/{team}/week{w}-coowner-")):
            cid = p.split("coowner-")[1][:-3]
            coowners.append({"id": cid, "text": read(p)})
        nights = {}
        for n in range(1, NIGHTS + 1):
            plan = read(f"{RUN}/{team}/week{w}-night{n}-plan.json")
            if plan is not None:
                plan = json.loads(plan)
                nights[n] = {"notes": plan.get("notes", ""), "requests": plan.get("requests") or [],
                             "reports": split_reports(read(f"{RUN}/{team}/week{w}-night{n}-reports.txt"))}
        t["weeks"][w] = {"note": note, "coowners": coowners, "nights": nights, "memo": read(f"{RUN}/{team}/week{w}-memo.md") or "",
                         "headlines": json.loads(read(f"{RUN}/{team}/week{w}-headlines.json") or "[]")}
    return t


TRACKS = {t: track(t) for t in TEAM_ORDER}
RENDERED = rendered_texts()


def norm(s):
    return re.sub(r"[^a-z0-9 ]+", " ", (s or "").lower()).split()


Q = []
for e in catalog["entries"]:
    tr = e["trace"]
    Q.append({"id": e["id"], "e": e, "team": tr["team"], "week": tr["week"], "night": tr["night"], "request": tr["request"],
              "engineer": tr.get("engineer"), "analyst": tr.get("analyst"), "files": tr.get("files", {}),
              "builds_on": [], "followups": [], "cited": []})
BY_ID = {q["id"]: q for q in Q}
BY_TEAM = {}
for q in Q:
    BY_TEAM.setdefault(q["team"], []).append(q)

# builds_on: the analyst names earlier reports by title; matched to the team's earlier queries (inferred)
for q in Q:
    for title in q["e"].get("builds_on", []):
        words, best, score = set(norm(title)), None, 0.0
        for o in BY_TEAM[q["team"]]:
            if o["id"] >= q["id"]:
                break
            ow = set(norm(o["e"]["title"]))
            s = len(words & ow) / max(1, len(words | ow))
            if s > score:
                best, score = o, s
        if best and score >= 0.5 and best["id"] not in q["builds_on"]:
            q["builds_on"].append(best["id"])
            best["followups"].append(q["id"])

# memo passages that cite the report by its title (inferred)
for q in Q:
    memo = TRACKS[q["team"]]["weeks"].get(q["week"], {}).get("memo", "")
    title = re.sub(r"\s*\(.*?\)\s*$", "", q["e"]["title"] or "").strip().lower()
    if len(title) >= 12:
        for para in re.split(r"\n\s*\n|\n(?=[-*\d])", memo):
            if title[:40] in para.lower():
                q["cited"].append(para.strip())


def conversation(path):
    """The engineer's session as turns: what was asked, each tool call and its answer, what the engineer said."""
    raw = read(path)
    if raw is None:
        return None
    turns, context = [], 0
    for line in raw.splitlines():
        d = json.loads(line)
        if d.get("type") == "attachment":
            context += len(line)
            continue
        if d.get("type") not in ("user", "assistant"):
            continue
        c = d["message"]["content"]
        if isinstance(c, str):
            turns.append(("asked", c))
            continue
        for x in c:
            if x.get("type") == "text" and x["text"].strip():
                turns.append(("said", x["text"]))
            elif x.get("type") == "tool_use":
                name = x["name"].split("__")[-1]
                turns.append((name, x["input"]))
            elif x.get("type") == "tool_result":
                cont = x.get("content")
                text = "\n".join(y.get("text", "") for y in cont) if isinstance(cont, list) else str(cont)
                turns.append(("result", text))
    return {"turns": turns, "context_kb": context // 1024, "size_kb": len(raw) // 1024}


# ---------------------------------------------------------------------------------------------------------------
# Shared page parts

STYLE = """
.doc h1 { font-size: 36px; line-height: 1.15; margin: 4px 0 14px; letter-spacing: -0.015em; }
.doc .kicker { font-size: 15px; color: var(--muted); }
.doc .kicker a { color: var(--ink-2); }
.doc .lead { font-size: 20px; font-style: italic; color: var(--ink-2); margin: 0 0 10px; }
.byline { font-size: 15px; color: var(--muted); margin: 0; }
.cast { display: grid; grid-template-columns: repeat(3, 1fr); gap: 20px; margin: 22px 0 0; }
.cast > div { border-top: 1px solid var(--rule-strong); padding-top: 8px; font-size: 14.5px; line-height: 1.45; }
.cast .role { display: block; color: var(--muted); font-variant-caps: all-small-caps; letter-spacing: 0.06em; }
.cast b { display: block; font-weight: 600; font-size: 16px; margin: 1px 0 3px; }
.cast .about { color: var(--ink-2); }
.cast-note { font-size: 14px; color: var(--muted); margin: 12px 0 0; }
.cast-note + .story { margin-top: 48px; }
@media (max-width: 640px) { .cast { grid-template-columns: 1fr; gap: 12px; } }
.byline b { color: var(--ink-2); font-weight: 400; }
.doc h4 { font-size: 16px; margin: 14px 0 4px; }
.doc p { margin: 0 0 10px; }
.doc ul, .doc ol { padding-left: 1.3em; margin: 0 0 10px; }
.doc code { font-family: var(--mono); font-size: 0.82em; }
.qnav { display: flex; justify-content: space-between; gap: 16px; font-size: 15px; border-top: 1px solid var(--rule); margin-top: 56px; padding-top: 14px; }
.qnav a { color: var(--ink-2); text-decoration: none; }
.qnav a:hover { color: var(--wrong); }
.qnav .keys { color: var(--muted); font-size: 13px; }

/* The story: numbered steps down a hairline */
.story { list-style: none; margin: 40px 0 0; padding: 0; counter-reset: step; }
.step { position: relative; padding: 0 0 34px 44px; counter-increment: step; }
.step::before { content: counter(step); position: absolute; left: 0; top: 1px; width: 24px; height: 24px; border-radius: 50%;
  border: 1px solid var(--rule-strong); background: var(--paper); color: var(--ink-2); font-size: 13px; text-align: center; line-height: 22px;
  font-variant-numeric: lining-nums; }
.step::after { content: ""; position: absolute; left: 12px; top: 27px; bottom: 2px; width: 1px; background: var(--rule); }
.step:last-child::after { display: none; }
.step > h3 { font-size: 17px; font-weight: 600; margin: 0 0 2px; }
.step > .who { font-size: 14px; color: var(--muted); margin: 0 0 12px; }
.step > .who i { color: var(--ink-2); }
.step .body { color: var(--ink-2); }
.letter { border-left: 2px solid var(--rule); padding: 2px 0 2px 16px; }
.clamp { max-height: 15em; overflow: hidden; position: relative; }
.clamp::after { content: ""; position: absolute; left: 0; right: 0; bottom: 0; height: 4em; background: linear-gradient(transparent, var(--paper)); }
.clamp.open { max-height: none; }
.clamp.open::after { display: none; }
.more { font: inherit; font-size: 14px; color: var(--accent); background: none; border: 0; padding: 0; margin: 6px 0 0; cursor: pointer; }
details.fold { margin: 10px 0 0; }
details.fold > summary { cursor: pointer; font-size: 14px; color: var(--ink-2); list-style: none; }
details.fold > summary::before { content: "+ "; color: var(--muted); }
details.fold[open] > summary::before { content: "− "; }
details.fold > :not(summary) { margin-top: 10px; }
.request { border: 1px solid var(--rule); border-radius: 3px; padding: 14px 16px; margin: 12px 0 0; }
.request .t { font-weight: 600; color: var(--ink); }
.request dl { display: grid; grid-template-columns: 7.6em 1fr; gap: 4px 14px; margin: 8px 0 0; font-size: 15px; }
.request dt { color: var(--muted); font-variant-caps: all-small-caps; letter-spacing: 0.06em; }
.request dd { margin: 0; }
.request ul { margin: 0; padding-left: 1.1em; }
.attempt { margin: 14px 0 0; }
.attempt .lbl { font-size: 14px; color: var(--muted); margin-bottom: 6px; }
.attempt .lbl b { color: var(--ink); font-weight: 600; }
.said { font-style: italic; color: var(--ink-2); margin: 14px 0 0; }
pre.sql { margin: 0; padding: 12px 16px; background: var(--code-bg); border-radius: 3px; font: 12.5px/1.6 var(--mono); color: var(--ink);
  white-space: pre; overflow: auto; max-height: 360px; tab-size: 2; }
pre.sql .ln { display: block; }
pre.sql .ln.add { background: var(--accent-wash); box-shadow: inset 3px 0 var(--accent); }
pre.sql .ln.del { color: var(--wrong); text-decoration: line-through; text-decoration-color: color-mix(in srgb, var(--wrong) 50%, transparent); }
pre.report { margin: 0; padding: 12px 16px; border: 1px solid var(--rule); border-radius: 3px; font: 12px/1.5 var(--mono); color: var(--ink-2);
  white-space: pre; overflow: auto; max-height: 340px; }
.cites { margin: 0; padding: 0; list-style: none; }
.kind { display: inline-block; min-width: 7.6em; margin-right: 4px; color: var(--muted); font-size: 13px; font-variant-caps: all-small-caps; letter-spacing: 0.06em; }
.tabs { display: flex; flex-wrap: wrap; gap: 4px 16px; font-size: 14px; margin: 0 0 8px; }
.tabs .opt { font: inherit; text-align: left; color: var(--ink-2); background: none; border: 0; padding: 0 0 1px; cursor: pointer; border-bottom: 1px solid transparent; }
.tabs .opt[aria-pressed="true"] { color: var(--ink); border-bottom-color: var(--ink); }
mark.ph { background: var(--accent-wash); color: inherit; box-shadow: inset 0 -1px var(--accent); }
.cites li { margin: 0 0 12px; }
.qlinks { margin: 4px 0 0; padding: 0; list-style: none; }
.qlinks li { margin: 2px 0; }
.qlinks .id { font-variant-numeric: lining-nums; color: var(--muted); margin-right: 8px; }
.turns { margin: 0; padding: 0; list-style: none; font-size: 15px; }
.turns > li { margin: 0 0 12px; }
.turns .k { font-size: 13px; color: var(--muted); font-variant-caps: all-small-caps; letter-spacing: 0.06em; display: block; }
.turns pre.plain { margin: 4px 0 0; font: 12px/1.5 var(--mono); white-space: pre-wrap; color: var(--ink-2); max-height: 260px; overflow: auto; }
.svgchart text { font-family: var(--serif); font-size: 12.5px; fill: var(--muted); font-variant-numeric: lining-nums; }
.svgchart .lbl { fill: var(--ink-2); font-size: 13px; }
.svgchart .grid { stroke: var(--rule); }
.svgchart .tval { font-size: 11.5px; stroke: var(--paper); stroke-width: 3px; paint-order: stroke; stroke-linejoin: round; font-variant-numeric: lining-nums tabular-nums; }
.raw a { color: var(--ink-2); }
.whyfail { list-style: none; margin: 10px 0 0; padding: 0; font-size: 13.5px; color: var(--ink-2); }
.whyfail li { display: flex; gap: 10px; margin: 2px 0; }
.whyfail .who { flex: none; width: 9em; color: var(--muted); }
@media (max-width: 640px) { .doc h1 { font-size: 28px; } .step { padding-left: 36px; } .request dl { grid-template-columns: 1fr; } }
"""

TIP_JS = """
const tipEl = document.getElementById("tip");
document.querySelectorAll("[data-tip]").forEach(el => {
  el.addEventListener("mousemove", e => {
    tipEl.innerHTML = el.dataset.tip; tipEl.style.display = "block";
    const w = tipEl.offsetWidth, h = tipEl.offsetHeight;
    let x = e.clientX + 14, y = e.clientY + 14;
    if (x + w > innerWidth - 8) x = e.clientX - w - 14;
    if (y + h > innerHeight - 8) y = e.clientY - h - 14;
    x = Math.max(8, Math.min(x, innerWidth - w - 8)); y = Math.max(8, Math.min(y, innerHeight - h - 8));
    tipEl.style.transform = `translate(${x}px, ${y}px)`;
  });
  el.addEventListener("mouseleave", () => { tipEl.style.display = "none"; });
});
// on a touch screen: a tap elsewhere or a scroll closes the tooltip
addEventListener("pointerdown", e => { if (!e.target.closest("[data-tip]")) tipEl.style.display = "none"; });
addEventListener("scroll", () => { tipEl.style.display = "none"; }, { passive: true });
document.querySelectorAll(".systems").forEach(box => box.querySelectorAll(".tabs button").forEach(b => b.onclick = () => {
  box.querySelectorAll(".tabs button").forEach(x => x.setAttribute("aria-pressed", x === b));
  box.querySelectorAll("pre.rendered").forEach(p => p.hidden = p.dataset.g !== b.dataset.g);
}));
document.querySelectorAll("button.more").forEach(b => b.onclick = () => {
  const c = b.previousElementSibling; c.classList.toggle("open");
  b.textContent = c.classList.contains("open") ? b.dataset.less : b.dataset.more;
});
"""


def page(title, body, desc, script="", current=None):
    return f"""<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>{E(title)}</title>
<meta name="description" content="{E(desc)}">
<link rel="preload" href="../fonts/source-serif-4.woff2" as="font" type="font/woff2" crossorigin>
{build.head_extra("../")}
<link rel="stylesheet" href="../style.css?v={build.STYLE_VERSION}">
<style>{STYLE}</style>
</head>
<body>
<div class="page doc">
{build.topbar(current, "../")}
{body}
<footer>
  <span>DB Olympics · <a href="https://db.in.tum.de/~birler/">Altan Birler</a> · <a href="https://db.in.tum.de/~schmidt/">Tobias Schmidt</a></span>
  <span><a href="../index.html">Results</a> · <a href="index.html">Queries</a> · <a href="../methodology.html">Methodology</a> · <a href="../add-a-system.html">Add a system</a></span>
</footer>
</div>
<div class="tip" id="tip"></div>
<script>{TIP_JS}{script}</script>
</body>
</html>
"""


def clamp(html_text, more="Show all", less="Show less"):
    return (f'<div class="clamp">{html_text}</div>'
            f'<button class="more" type="button" data-more="{more}" data-less="{less}">{more}</button>')


def person(team):
    m = MANAGERS[team]
    return m["name"], m["title"]


def night_label(w, n):
    return f"week {w}, night {n}"


def raw_link(path, label):
    if not path:
        return ""
    size = f" ({max(1, os.path.getsize(os.path.join(RUNS, path.split("/", 1)[1])) // 1024)} KB)" if path in NAMES_IN_ARCHIVE else ""
    return f'<a href="../raw/{E(path)}">{E(label)}</a>{size}'


# ---------------------------------------------------------------------------------------------------------------
# A query page

# the machine of the query pages' times: the largest at the default scale factor
DEFAULT_MACHINE = build.sf_machines(build.DEFAULT_SF)[-1]


def dots_svg(qid):
    """The query's time on every native system at the default configuration, as on the start page's query panel."""
    c = next(c for c in build.D["categories"][build.DEFAULT_CATEGORY].values() if c["sf"] == build.DEFAULT_SF and c["machine"] == DEFAULT_MACHINE)
    i = next(k for k, q in enumerate(build.D["queries"]) if q["id"] == qid)
    rows = sorted(((n, s) for n, s in c["systems"].items() if s["status"][i] != 4), key=lambda r: r[1]["score"])
    timeout = c["timeout"]
    timeouts = any(s["status"][i] == 3 for _, s in rows)
    ts = [s["times"][i] for _, s in rows if s["status"][i] == 0] + ([timeout] if timeouts else [])
    if not ts:
        return ""
    lo = math.floor(math.log10(min(ts + [5])))
    hi = math.log10(timeout) if timeouts else max(math.ceil(math.log10(max(ts))), lo + 1)
    # as on the start page (drawDots): on the right as much room as the query needs, half of the last tick label,
    # the timeout label, or the time next to a circle near the right end (about 6.2 px a character)
    W, L, RH, T = 560, 140, 22, 6
    R = 96 if timeouts else 30
    H = T + len(rows) * RH + 30
    X = lambda t: L + (math.log10(t) - lo) / (hi - lo) * (W - L - R)
    fmt = lambda t: f"{float(f'{t * 1000:.3g}'):g} ms" if t < 1 else f"{float(f'{t:.3g}'):g} s"
    def fmt_t(t):  # as the start page's fmtT: 2 significant digits under 10 ms, else 3, trailing zeros kept
        v, unit, p = (t * 1000, "ms", 2 if t < 0.01 else 3) if t < 1 else (t, "s", 3)
        return f"{v:#.{p}g}".rstrip(".") + f" {unit}"
    tw = lambda t: 9 + len(fmt_t(t)) * 6.2
    for _ in range(4):
        over = max([X(s["times"][i]) + tw(s["times"][i]) - W for _, s in rows if s["status"][i] == 0] + [0])
        if over <= 0:
            break
        R += over + 2
    o = [f'<svg viewBox="0 0 {W} {H}" style="width:100%;max-width:{W}px;height:auto" role="img" aria-label="Time per system">']
    grid = [10 ** e for e in range(lo, math.floor(hi) + 1)] + ([timeout] if timeouts else [])
    # every grid line, but a tick label only where it does not run into the next one to its right
    shown, right = set(), float("inf")
    for v in reversed(grid):
        w = len(fmt(v)) * 6.5
        if X(v) + w / 2 + 6 <= right:
            shown.add(v); right = X(v) - w / 2
    for v in grid:
        o.append(f'<line class="grid" x1="{X(v):.1f}" x2="{X(v):.1f}" y1="{T}" y2="{H - 24}"/>'
                 + (f'<text x="{X(v):.1f}" y="{H - 8}" text-anchor="middle">{fmt(v)}</text>' if v in shown else ""))
    for r, (n, s) in enumerate(rows):
        y = T + r * RH + RH / 2
        st = s["status"][i]
        o.append(f'<text class="lbl" x="0" y="{y + 4}">{build.NAMES[n]}</text>')
        if st == 0:
            t = s["times"][i]
            o.append(f'<line x1="{L}" x2="{X(t):.1f}" y1="{y}" y2="{y}" stroke="var(--rule)"/>'
                     f'<circle cx="{X(t):.1f}" cy="{y}" r="4" fill="var(--ink)" data-tip="{E(build.NAMES[n])}: {fmt_t(t)}"/>'
                     f'<text class="tval" x="{X(t) + 9:.1f}" y="{y + 4}" style="fill:var(--ink-2)">{fmt_t(t)}</text>')
        elif st == 3:
            o.append(f'<line x1="{L}" x2="{X(timeout):.1f}" y1="{y}" y2="{y}" stroke="var(--timeout)" stroke-width="2.5"/>'
                     f'<text x="{X(timeout) + 7:.1f}" y="{y + 4}" style="fill:var(--timeout);font-style:italic">timeout ({fmt(timeout)})</text>')
        else:
            col, label = ("var(--wrong)", "wrong result") if st == 1 else ("var(--muted)", "error")
            o.append(f'<text x="{L}" y="{y + 4}" style="fill:{col};font-style:italic">{label}</text>')
    o.append("</svg>")
    msgs = [(build.NAMES[n], s["messages"][str(i)]) for n, s in rows if str(i) in s.get("messages", {})]
    if msgs:
        o.append('<ul class="whyfail">' + "".join(f'<li><span class="who">{E(n)}</span>{E(m)}</li>' for n, m in msgs) + "</ul>")
    return "".join(o)


def query_page(q, prev_q, next_q):
    e, t = q["e"], TRACKS[q["team"]]
    wk = t["weeks"].get(q["week"], {})
    night = wk.get("nights", {}).get(q["night"], {})
    reqs = night.get("requests", [])
    req = reqs[q["request"] - 1] if 0 < q["request"] <= len(reqs) else {}
    mname, mtitle = person(q["team"])
    analyst = q["analyst"] or ""
    steps = []

    # 1. the situation, when it had arrived by then
    sit = t["situation"]
    if sit and q["week"] >= sit.get("week", 1):
        others = [f'{E(MANAGERS[x]["name"])}, {E(MANAGERS[x]["title"])}' for x in sit.get("with", []) if x in MANAGERS]
        how = ("it shaped the manager's first note" if sit.get("week", 1) == 1
               else f"the manager heard of it at the start of week {sit['week']} and had to cover it in that week's note")
        steps.append((f"A business event lands on the {E(mtitle)}'s desk",
                      f'Week {sit.get("week", 1)}' + (f'; shared with {" and ".join(others)}' if others else ""),
                      f'<div class="body"><p>{inline(sit["text"])}</p></div>'
                      f'<p class="byline">One of the {len(EVENT_POOL)} events we wrote for the role play; {how}. '
                      f'<a href="index.html#events">How events arise</a> · <a href="index.html#event-{sit["id"]}">All the events</a></p>'))

    # 2. the manager's note of the week, and notes from co-owners
    co = "".join(f'<details class="fold"><summary>A note from the {E(MANAGERS.get(c["id"], {}).get("title", c["id"]))}, '
                 f'{E(MANAGERS.get(c["id"], {}).get("name", ""))}</summary><div class="letter body">{md(c["text"])}</div></details>'
                 for c in wk.get("coowners", []))
    steps.append((f"{E(mname)} writes to {E(analyst)}", f"The manager, at the start of week {q['week']}",
                  f'<div class="letter body">{clamp(md(wk.get("note", "")), "Show the whole note", "Show less")}</div>{co}'))

    # 3. the analyst plans the night
    cols = req.get("columns") or []
    request = (f'<div class="request"><div class="t">{inline(req.get("title", e["title"]))}</div><dl>'
               f'<dt>Question</dt><dd>{inline(req.get("question", e["question"]))}</dd>'
               + (f'<dt>One row per</dt><dd>{inline(re.sub(r"^one row per ", "", req["grain"]))}</dd>' if req.get("grain") else "")
               + (f'<dt>Columns</dt><dd><ul>{"".join(f"<li>{inline(c)}</li>" for c in cols)}</ul></dd>' if cols else "")
               + "</dl></div>")
    steps.append((f"{E(analyst)} plans the night", f"The analyst · {night_label(q['week'], q['night'])}, "
                  f"request {q['request']} of {len(reqs)}",
                  f'<div class="body">{clamp(md(night.get("notes", "")), "Read the whole plan", "Show less")}</div>{request}'))

    # 4. the engineer writes the SQL: every dry run, then the submission, each against the attempt before
    thread = json.loads(read(f"{RUN}/{q['files']['engineer_thread'].split('/', 1)[1]}") or "[]") if q["files"].get("engineer_thread") else []
    eng = q["engineer"] or "The engineer"
    attempts, prev_sql, k = [], None, 0
    for s in thread:
        if s["kind"] in ("dry_run", "submit"):
            k += 1
            label = "Submitted" if s["kind"] == "submit" else f"Dry run {k}"
            if prev_sql is None:
                block, note = sql_block(s["sql"]), ""
            else:
                block, changed = diff_block(prev_sql, s["sql"])
                note = f" · {changed} change{'s' if changed != 1 else ''} from the dry run before"
                if not changed:
                    block, note = "", " · the SQL of the last dry run, unchanged"
            res = (s.get("result") or "").strip().splitlines()
            res = f' · <span title="{E(chr(10).join(res))}">{E(res[0][:90])}</span>' if res else ""
            attempts.append(f'<div class="attempt"><div class="lbl"><b>{label}</b>{note}{res}</div>{block}</div>')
            prev_sql = s["sql"]
        elif s["kind"] == "text" and s.get("text", "").strip():
            attempts.append(f'<p class="said">“{inline(s["text"].strip())}”</p>')
    dry = sum(1 for s in thread if s["kind"] == "dry_run")
    steps.append((f"{E(eng)} writes the SQL", f"The engineer · "
                  f"{dry} dry run{'s' if dry != 1 else ''} on the empty schema, then the submission",
                  "".join(attempts) or sql_block(e["sql"])))

    # 5. the report as the analyst saw it
    report = night.get("reports", {}).get(q["request"], "")
    if report:
        steps.append(("The report comes back overnight", f"As {E(analyst)} saw it, from the small dataset the agents worked on",
                      f'<pre class="report">{E(report)}</pre>'))

    # 6. what came of it
    nxt = []
    if q["cited"]:
        nxt.append(f'<p>{E(analyst)}\'s memo to {E(mname)} at the end of the week:</p><ul class="cites">'
                   + "".join(f'<li class="letter">{md(c)}</li>' for c in q["cited"]) + "</ul>")
    if q["followups"]:
        nxt.append("<p>Later queries that build on this report:</p>" + qlist(q["followups"]))
    if q["builds_on"]:
        nxt.append("<p>It builds on:</p>" + qlist(q["builds_on"]))
    if nxt:
        steps.append(("What came of it", "The memo and the queries that followed; links found by title, so inferred", "".join(nxt)))

    # 7. the benchmark query
    canon = open(os.path.join(ROOT, "workload", "queries", f"{q['id']}.sql")).read()
    dv = derivations.get(q["id"], [])
    label = {"hard": "spelling", "dialect": "placeholder", "portability": "made explicit", "determinism": "determinism",
             "numeric": "numerics", "manual": "edit"}
    changes = "".join(f"<li><span class=\"kind\">{label.get(d['kind'], d['kind'])}</span>{inline(d.get('note') or d['step'].replace('_', ' '))}"
                      + (f" ({d['count']}×)" if d.get("count", 1) > 1 else "") + "</li>" for d in dv)
    block, _ = diff_block(e["sql"], canon)
    steps.append(("It becomes benchmark query " + q["id"],
                  "Changed only where the benchmark needs the same result on every system",
                  (f'<ul class="body">{changes}</ul>' if changes else '<p class="body">Taken as written.</p>')
                  + f'<details class="fold"><summary>The benchmark text, against the submitted SQL</summary>{block}</details>'
                  + per_system(q["id"])
                  + f'<div style="margin-top:18px" class="svgchart">{dots_svg(q["id"])}</div>'
                  + f'<p class="byline" style="margin-top:6px">Scale factor {build.DEFAULT_SF}, {DEFAULT_MACHINE}, after the last load. '
                    f'<a href="../index.html#{q["id"]}">{q["id"]} on the start page</a>, with every configuration.</p>'))

    # 8. everything, unedited
    conv = conversation(q["files"].get("engineer_transcript"))
    turns = ""
    if conv:
        items = []
        for kind, v in conv["turns"]:
            if kind == "asked":
                items.append(f'<li><span class="k">The request, as {E(eng)} received it</span><pre class="plain">{E(v)}</pre></li>')
            elif kind == "said":
                items.append(f'<li><span class="k">{E(eng)}</span>{E(v)}</li>')
            elif kind == "result":
                items.append(f'<li><span class="k">The warehouse answers</span><pre class="plain">{E(v)}</pre></li>')
            else:
                items.append(f'<li><span class="k">{E(eng)} calls <code>{E(kind)}</code></span>'
                             + (sql_block(v["sql"]) if isinstance(v, dict) and "sql" in v else f'<pre class="plain">{E(json.dumps(v, indent=1))}</pre>')
                             + "</li>")
        turns = (f'<details class="fold"><summary>{E(eng)}\'s whole session, {len(conv["turns"])} turns</summary>'
                 f'<ul class="turns">{"".join(items)}</ul>'
                 f'<p class="byline">Not shown here: {conv["context_kb"]} KB of context the agent was given, its instructions and '
                 f'the schema documentation; it is in the raw transcript.</p></details>')
    f = q["files"]
    raws = [raw_link(f.get("engineer_transcript"), f"{eng}'s transcript"), raw_link(f.get("analyst_transcript"), f"{analyst}'s transcript"),
            raw_link(f"{RUN}/{q['team']}/transcripts/manager.jsonl", f"{mname}'s transcript"),
            raw_link(f.get("plan"), "the night's plan"), raw_link(f.get("reports"), "the night's reports"),
            raw_link(f.get("memo"), "the week's memo")]
    steps.append(("Everything, as recorded", "The agents' own records, as the role play wrote them; only the personal data "
                  'of the person who ran it is <a href="../raw/REDACTIONS.md">redacted</a>',
                  turns + f'<p class="raw byline" style="margin-top:12px">{" · ".join(r for r in raws if r)}</p>'))

    story = "".join(f'<li class="step"><h3>{h}</h3><p class="who">{who}</p>{body}</li>' for h, who, body in steps)
    nav = (f'<nav class="qnav"><a href="{prev_q["id"]}.html" data-key="ArrowLeft">← {prev_q["id"]}</a>'
           f'<span class="keys">or the arrow keys</span><a href="{next_q["id"]}.html" data-key="ArrowRight">{next_q["id"]} →</a></nav>')
    body = (f'<p class="kicker"><a href="index.html">Queries</a> · {q["id"]} · '
            f'<a href="index.html#team-{q["team"]}">{E(mtitle)}</a> · {night_label(q["week"], q["night"])}</p>'
            f'<h1>{inline(e["title"])}</h1><p class="lead measure">“{inline(e["question"])}”</p>'
            f'{cast(q, mname, mtitle, analyst, eng)}'
            f'<ol class="story measure">{story}</ol>{nav}')
    keys = """
addEventListener("keydown", e => {
  if (e.altKey || e.ctrlKey || e.metaKey || e.shiftKey || e.target.closest("input, textarea")) return;
  const a = document.querySelector(`.qnav a[data-key="${e.key}"]`);
  if (a) location.href = a.href;
});"""
    return page(f"{q['id']}: {e['title']} · DB Olympics", body, e["question"], keys)


def cast(q, mname, mtitle, analyst, eng):
    """Who the three people behind a query are, from the personas of the role play."""
    def sentence(s):
        s = (s or "").strip()
        return s[0].upper() + s[1:] + ("" if s.endswith(".") else ".") if s else ""
    people = [("Manager · asked the question", mname, f"{mtitle}. {MANAGERS[q['team']].get('background', '')}"),
              ("Analyst · planned the report", analyst, sentence(ANALYST_STYLE.get(analyst))),
              ("Engineer · wrote the SQL", eng, sentence(ENGINEER_STYLE.get(q["engineer"])))]
    cells = "".join(f'<div><span class="role">{role}</span><b>{E(name)}</b><span class="about">{inline(about)}</span></div>'
                    for role, name, about in people)
    return (f'<div class="cast">{cells}</div><p class="cast-note">Fictional people at a fictional company, each played by a '
            f'language-model agent. <a href="index.html#people">Who they are and what they are told</a></p>')


def per_system(qid):
    """The text each system received, identical texts together, the placeholders highlighted."""
    groups = {}
    for n, texts in RENDERED.items():
        if qid in texts:
            groups.setdefault(texts[qid], []).append(n)
    if not groups:
        return ""
    tabs = "".join(f'<button type="button" class="opt" aria-pressed="{str(k == 0).lower()}" data-g="{k}">'
                   f'{E(" · ".join(build.NAMES[n] for n in ns))}</button>' for k, ns in enumerate(groups.values()))
    pres = "".join(f'<pre class="sql rendered" data-g="{k}"{"" if k == 0 else " hidden"}>{marked_sql(t)}</pre>'
                   for k, t in enumerate(groups))
    return (f'<div class="systems"><p class="byline" style="margin:14px 0 6px">As each system received it; '
            f'<mark class="ph">highlighted</mark>, the parts spelled for that system</p>'
            f'<div class="tabs">{tabs}</div>{pres}</div>')


def qlist(ids):
    return '<ul class="qlinks">' + "".join(f'<li><span class="id">{i}</span><a href="{i}.html">{inline(BY_ID[i]["e"]["title"])}</a></li>'
                                           for i in ids) + "</ul>"


# ---------------------------------------------------------------------------------------------------------------
# The overview: how the queries came about, and every query by team

OVERVIEW_STYLE = """
.steps4 { display: grid; grid-template-columns: repeat(4, 1fr); gap: 18px; margin: 28px 0 0; counter-reset: s; }
.steps4 div { border-top: 2px solid var(--ink); padding-top: 10px; font-size: 15px; color: var(--ink-2); counter-increment: s; }
.steps4 b { display: block; color: var(--ink); font-weight: 600; margin-bottom: 4px; }
.steps4 b::before { content: counter(s) "  "; color: var(--muted); font-weight: 400; }
.teams { columns: 2; column-gap: 40px; margin-top: 10px; }
.team { break-inside: avoid; margin: 0 0 26px; }
.team h3 { font-size: 17px; font-weight: 600; margin: 0; }
.team .who { font-size: 14px; color: var(--muted); margin: 0 0 6px; }
.team .qlinks { font-size: 15px; }
h3.sub { font-size: 16px; font-weight: 600; margin: 28px 0 10px; }
.people { display: grid; grid-template-columns: repeat(2, 1fr); gap: 18px 32px; }
.people.three { grid-template-columns: repeat(3, 1fr); }
.person { border-top: 1px solid var(--rule); padding-top: 8px; font-size: 14.5px; line-height: 1.45; }
.person .role { display: block; color: var(--muted); font-variant-caps: all-small-caps; letter-spacing: 0.06em; }
.person > b { display: block; font-weight: 600; font-size: 16px; margin: 1px 0 3px; }
.person span { display: block; color: var(--ink-2); }
.person .remit { color: var(--muted); margin-top: 4px; }
.person .aide { margin-top: 6px; }
.person .aide b { font-weight: 600; color: var(--ink); }
.rules { padding-left: 1.2em; color: var(--ink-2); }
.rules li { margin-bottom: 4px; }
#events p { color: var(--ink-2); margin: 0 0 10px; }
#events b { color: var(--ink); font-weight: 600; }
.events { max-width: 640px; }
.events h4 { font-size: 15px; font-weight: 600; margin: 20px 0 6px; color: var(--ink); }
.evlist { list-style: none; margin: 0; padding: 0; }
.evlist li { color: var(--ink-2); padding: 6px 0 6px 14px; border-left: 2px solid var(--rule); margin: 0 0 8px; font-size: 15.5px; }
.evlist li.arrived { border-left-color: var(--timeout); }
.evlist li:target { background: var(--accent-wash); }
.evlist .meta { display: block; font-size: 13.5px; color: var(--muted); margin-top: 3px; }
.evlist .meta b { color: var(--ink-2); font-weight: 600; }
@media (max-width: 760px) { .steps4 { grid-template-columns: 1fr 1fr; } .teams { columns: 1; } .people, .people.three { grid-template-columns: 1fr; } }
"""


def events():
    """How the questions start: onboarding for everyone, and business events for some."""
    got = [t for t in TEAM_ORDER if TRACKS[t]["situation"]]
    by_week = {}
    for t in got:
        by_week.setdefault(TRACKS[t]["situation"].get("week", 1), []).append(t)
    weeks = "; ".join(f"{len(v)} in week {w}" for w, v in sorted(by_week.items()))
    return f"""
<section id="events">
  <h2>How the questions start</h2>
  <div class="measure">
    <p><b>Every manager is new in the job.</b> Their first note asks their analyst to help them understand their area:
      what is going well, what is not, and where the money is.</p>
    <p><b>On top of that, a business event can arrive.</b> We wrote {len(EVENT_POOL)} ordinary business events for the
      role play, each led by one manager and sometimes shared with others: the board asks for unit economics, the year-end
      audit, a post-mortem of the peak season, a churn task force. Each week, a team without an event got one of its
      manager's with a chance of {EVENT_CHANCE:g}, drawn from the run's fixed seed. {len(got)} of the {len(TEAM_ORDER)} teams got
      one ({weeks}); a yellow rule marks them in the list below.</p>
    <p><b>The event reaches the manager as news.</b> In week 1 it is the subject of their first note; later it comes
      with their reply to the analyst's memo, and they have to cover it in that week's note. Managers who share the
      event also write to the analyst.</p>
    <p>Everything after that is the agents' own doing: what to ask, which reports to plan, how to write the SQL.
      Which models played them, and where else AI was used, is in <a href="../methodology.html#ai">the methodology</a>.</p>
  </div>
  <details class="fold events" id="all-events"><summary>Read all {len(EVENT_POOL)} events</summary>{event_list()}</details>
</section>"""


def event_list():
    """Every event of the pool, grouped by the manager who leads it, and whether it arrived in this run."""
    arrived = {TRACKS[t]["situation"]["id"]: (t, TRACKS[t]["situation"].get("week", 1)) for t in TEAM_ORDER if TRACKS[t]["situation"]}
    out = []
    for lead in TEAM_ORDER:
        own = [s for s in EVENT_POOL if s["lead"] == lead]
        if not own:
            continue
        items = []
        for s in own:
            shared = [MANAGERS[x]["title"] for x in s.get("with", []) if x in MANAGERS]
            meta = [f"shared with the {' and the '.join(E(x) for x in shared)}"] if shared else []
            if s["id"] in arrived:
                team, week = arrived[s["id"]]
                meta.append(f'<b>arrived in week {week}</b>: <a href="#team-{team}">the team\'s queries</a>')
            items.append(f'<li id="event-{s["id"]}"{" class=arrived" if s["id"] in arrived else ""}>{inline(s["text"])}'
                         + (f'<span class="meta">{"; ".join(meta)}</span>' if meta else "") + "</li>")
        out.append(f'<h4>{E(MANAGERS[lead]["title"])}, {E(MANAGERS[lead]["name"])}</h4><ul class="evlist">{"".join(items)}</ul>')
    return "".join(out)


def people():
    """The cast: every manager with their analyst, and the engineers, described in the words of their prompts."""
    n_by_eng = {}
    for q in Q:
        n_by_eng[q["engineer"]] = n_by_eng.get(q["engineer"], 0) + 1
    teams = []
    for team in TEAM_ORDER:
        m = MANAGERS[team]
        qs = BY_TEAM.get(team, [])
        analyst = qs[0]["analyst"] if qs else ""
        teams.append(f'<div class="person"><span class="role">{E(m["title"])}</span><b>{E(m["name"])}</b>'
                     f'<span class="about">“{inline(m.get("background", ""))}”</span>'
                     f'<span class="remit">Remit: “{inline(m.get("remit", ""))}”</span>'
                     f'<span class="aide">Analyst <b>{E(analyst)}</b>: “{inline(ANALYST_STYLE.get(analyst, ""))}”</span></div>')
    engineers = "".join(f'<div class="person"><span class="role">Engineer · {n_by_eng.get(e["name"], 0)} queries</span><b>{E(e["name"])}</b>'
                        f'<span class="about">“{inline(e["style"])}”</span></div>' for e in personas["engineers"])
    return f"""
<section id="people">
  <h2>The people</h2>
  <p class="measure">Everyone at Tidewick is a language-model agent playing a persona: the managers have a title, a
    background and a remit; the analysts a way of working; the engineers a way of writing SQL. What follows is quoted
    from their prompts. Each of the {len(TEAM_ORDER)} managers has their own analyst; the {len(personas["engineers"])}
    engineers work for every team, one request at a time.</p>
  <h3 class="sub">Managers and their analysts</h3>
  <div class="people">{"".join(teams)}</div>
  <h3 class="sub">Engineers</h3>
  <div class="people three">{engineers}</div>
  <h3 class="sub">What they are told</h3>
  <ul class="measure rules">
    <li>The warehouse is shared and metered, and every executed query is billed to the department, so reports run as an
      overnight batch.</li>
    <li>An analyst has three report slots a night and four nights a week. A slot is spent whenever a request is
      submitted, whether it runs, fails or is bounced.</li>
    <li>A report is one table at one grain, and at most 50 rows are printed.</li>
    <li>Checking a query against an empty copy of the schema, a dry run, is free.</li>
  </ul>
  <p class="measure">So the agents think before they ask, and pack a question into one dense query rather than many
    small probes. They are never told that their SQL becomes a benchmark.</p>
</section>"""


def overview():
    teams = []
    for team in TEAM_ORDER:
        m = MANAGERS[team]
        qs = BY_TEAM.get(team, [])
        analyst = qs[0]["analyst"] if qs else ""
        teams.append(f'<div class="team" id="team-{team}"><h3>{E(m["title"])}</h3>'
                     f'<p class="who">{E(m["name"])}, with {E(analyst)} as analyst · {len(qs)} queries</p>{qlist([q["id"] for q in qs])}</div>')
    body = f"""
<h1>Where the queries come from</h1>
<p class="lead measure" style="font-style:normal">For two simulated weeks, language-model agents ran Tidewick's analytics: {len(TEAM_ORDER)}
  managers asked their analysts questions, the analysts turned them into report requests, and engineers wrote the SQL.</p>
<div class="steps4">
  <div><b>Request</b>Each Monday, a manager writes to their analyst: what they need to understand this week.</div>
  <div><b>Plan</b>Each night, the analyst plans up to three reports: a question, one row per what, which columns.</div>
  <div><b>SQL</b>An engineer writes each report's query, tries it on the empty schema, and submits it to the overnight batch.</div>
  <div><b>Report</b>The reports come back in the morning; at the end of the week the analyst sums them up in a memo.</div>
</div>
{events()}
{people()}
<section>
  <h2>Every query, by team</h2>
  <div class="teams">{"".join(teams)}</div>
</section>"""
    links_js = """
function openEvent() {
  const el = location.hash.startsWith("#event-") && document.getElementById(location.hash.slice(1));
  if (el) { document.getElementById("all-events").open = true; el.scrollIntoView({ block: "center" }); }
}
openEvent();
addEventListener("hashchange", openEvent);
"""
    return page("Where the queries come from · DB Olympics", body,
                "How every DB Olympics query came about: the notes, plans, SQL and reports of a simulated analytics department.", links_js,
                current="queries").replace(
        f"<style>{STYLE}</style>", f"<style>{STYLE}{OVERVIEW_STYLE}</style>")


def main():
    os.makedirs(OUT, exist_ok=True)
    open(os.path.join(OUT, "index.html"), "w").write(overview())
    for k, q in enumerate(Q):
        open(os.path.join(OUT, f"{q['id']}.html"), "w").write(query_page(q, Q[k - 1], Q[(k + 1) % len(Q)]))
    print(f"queries/: index.html and {len(Q)} query pages")
    if "--raw" in sys.argv:
        dest = os.path.join(SITE, "raw")
        shutil.rmtree(dest, ignore_errors=True)
        shutil.copytree(RUNS, os.path.join(dest, RUN), ignore=lambda d, names: ["README.md"] if d == RUNS else [])
        for name in NAMES_IN_ARCHIVE:
            text = read(name)
            for what in REDACTED:
                REDACTED[what] += text.count(f"[redacted: {what}]")
        lines = "\n".join(f"| {what} | `[redacted: {what}]` | {n} |" for what, n in REDACTED.items())
        open(os.path.join(dest, "REDACTIONS.md"), "w").write(
            f"# Redactions\n\nThese files are the role-play run `{RUN}` as archived, with the personal data of the person who ran it\n"
            "replaced by a marker. Claude Code put it into the transcripts as context; the agents never used it.\n"
            "Nothing else is changed.\n\n| What | Replaced by | Times |\n|---|---|---|\n" + lines + "\n")
        print(f"raw/: the archive {RUN}, redacted: {REDACTED}")


if __name__ == "__main__":
    main()
