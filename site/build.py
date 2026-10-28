"""Build the start page, the methodology and the page for adding a system: index.template.html,
methodology.template.html, add-a-system.template.html + out/data.json -> out/index.html, out/methodology.html,
out/add-a-system.html, with the stylesheet and fonts copied next to them.

The hero figure (queries per second against the cost of running all queries) is rendered here to inline SVG, one per scale
factor in a wide and a narrow layout, so it is on the page as soon as the HTML arrives. Hover highlighting is CSS;
the remaining sections are drawn by the page's script from data.js.
"""
import glob, hashlib, html, json, math, os, random, re, shutil, subprocess

HERE = os.path.dirname(os.path.abspath(__file__))  # site/: the scripts, templates, stylesheet and fonts
ROOT = os.path.dirname(HERE)                         # the repository
OUT = os.path.join(HERE, "out")                      # everything built; not checked in
D = json.load(open(os.path.join(OUT, "data.json")))
# the scale factor shown first: the largest in the results
DEFAULT_SF = max(c["sf"] for c in D["configs"].values())
NQ = len(D["queries"])

NAMES = {
    "duckdb": "DuckDB", "hyper": "Hyper", "hardcharger": "Hardcharger", "cedardb": "CedarDB", "umbra": "Umbra",
    "pg_duckdb": "pg_duckdb", "postgres": "PostgreSQL", "datafusion": "DataFusion", "firebolt": "Firebolt",
    "clickhouse": "ClickHouse", "chdb": "chDB", "pg_clickhouse": "pg_clickhouse",
    "pg_brew": "pg_brew", "clickhouse_brew": "clickhouse_brew",
}
# USD per hour, on demand, Linux, us-east-1 (October 2026): AWS prices c8a by the vCPU, $0.053885 each
PRICE_H = {"c8a.medium": 0.0539, "c8a.large": 0.1078, "c8a.xlarge": 0.2155, "c8a.2xlarge": 0.4311, "c8a.4xlarge": 0.8622,
           "c8a.8xlarge": 1.7243, "c8a.12xlarge": 2.5865, "c8a.16xlarge": 3.4486, "c8a.24xlarge": 5.1730}

# ---------------------------------------------------------------------------------------------------------------
# Marks for the systems: systems/<name>/logo.svg, which a system may replace with any SVG. It is fitted into the 16x16
# grid the figures draw marks on: its viewBox (else its width and height) scaled to 16 on the longer side, centred,
# the aspect ratio kept. In it, currentColor is the text colour (the highlights of a hovered or selected system come
# through it) and var(--paper) the background; a mark with colours of its own keeps them. Ours are drawn on 16x16 in
# families: a duck head for systems built on DuckDB, bars for ClickHouse, a PostgreSQL extension the outline of its
# engine's mark, Querybrew Umbra's mark with the target's in its open half.
DEFAULT_GLYPH = '<circle cx="8" cy="8" r="5.5" fill="currentColor"/>'  # a system without a logo.svg

def load_glyph(name):
    path = os.path.join(ROOT, "systems", name, "logo.svg")
    if not os.path.isfile(path):
        return DEFAULT_GLYPH
    text = re.sub(r"<\?xml.*?\?>|<!--.*?-->|<!DOCTYPE[^>]*>", "", open(path).read(), flags=re.S)
    m = re.search(r"<svg\b([^>]*)>(.*)</svg>", text, re.S)
    assert m, f"{path}: no <svg> element"
    attrs, inner = m.groups()
    vb = re.search(r"viewBox\s*=\s*[\"']([^\"']+)", attrs)
    if vb:
        x0, y0, w, h = map(float, re.split(r"[\s,]+", vb.group(1).strip()))
    else:
        size = lambda k: float(re.search(rf"\b{k}\s*=\s*[\"']([\d.]+)", attrs).group(1))
        x0, y0, w, h = 0.0, 0.0, size("width"), size("height")
    inner = " ".join(line.strip() for line in inner.strip().splitlines())
    if (x0, y0, w, h) == (0, 0, 16, 16):
        return inner
    k = 16 / max(w, h)
    return f'<g transform="translate({(16 - w * k) / 2 - x0 * k:g} {(16 - h * k) / 2 - y0 * k:g}) scale({k:g})">{inner}</g>'

GLYPHS = {name: load_glyph(name) for name in NAMES}

# ---------------------------------------------------------------------------------------------------------------
# The logo: the stacked disks that stand for a database, five of them, alternating left and right so that they
# fall into the three-and-two pattern of the Olympic rings.

def logo(height):
    w, rx, ry, t, gap = 26, 13, 4.2, 5, 8
    xs = [2, 16, 2, 16, 2]  # three disks left, two right
    parts = []
    for i in reversed(range(5)):  # bottom disk first, so every disk sits on the one below
        x, y = xs[i], 4 + i * gap
        parts.append(f'<path d="M{x} {y}v{t}a{rx} {ry} 0 0 0 {w} 0v{-t}" fill="var(--paper)" stroke="currentColor" stroke-width="1.6"/>')
        parts.append(f'<ellipse cx="{x + rx}" cy="{y}" rx="{rx}" ry="{ry}" fill="var(--paper)" stroke="currentColor" stroke-width="1.6"/>')
    top, bottom = 4 - ry - 1.2, 4 + 4 * gap + t + ry + 1.2  # outer edges of the first and last disk, with the stroke
    vb_w, vb_h = 44, bottom - top
    return (f'<svg class="logo" viewBox="0 {top:g} {vb_w} {vb_h:g}" height="{height}" width="{height * vb_w / vb_h:.1f}" '
            f'role="img" aria-label="DB Olympics logo">{"".join(parts)}</svg>')

# ---------------------------------------------------------------------------------------------------------------
# The hero figure

def points(sf):
    cfgs = sorted((c for c in D["configs"].values() if c["sf"] == sf), key=lambda c: machine_order(c["machine"]))
    pts = []
    for m, c in enumerate(cfgs):
        # a query without a correct result counts as in Table 1 (extract.py): a timeout the timeout, anything else twice
        # the slowest correct time of that query
        cost = lambda s, i: s["times"][i] if s["status"][i] == 0 else c["timeout"] if s["status"][i] == 3 else 2 * c["worst"][i]
        for name, s in c["systems"].items():
            if s["failed"]:  # a run that did not finish has no last round
                continue
            # all queries once after the last load
            secs = sum(cost(s, i) for i in range(NQ))
            pts.append({"name": name, "machine": c["machine"], "rank": m, "of": len(cfgs), "secs": secs,
                        "dollars": price_h(c["machine"]) / 3600 * secs, "correct": s["correct"], "qps": NQ / secs})
    return pts

def fmt_usd(v):
    """$0.0005, $0.02, $1: as many decimals as the value's first digit needs."""
    return f"${v:.{max(0, -math.floor(math.log10(v)))}f}"

def fmt_usd2(v):
    """$0.00098, $0.0010, $0.012: two significant digits, for numbers read side by side."""
    return f"${round(v)}" if v >= 99.5 else "$" + f"{v:#.2g}".rstrip(".")  # rounded first: 0.996 is $1.0, as 1.04

def fmt_step(v, step, prefix=""):
    """A tick of a linear axis, its decimals from the step, so that every tick is exact and they differ: $0, $0.25,
    $0.50 for a step of 0.25; with k or M where the step is that large (1.5k, 2k)."""
    if not v:
        return f"{prefix}0"
    unit, div = next(((u, d) for u, d in (("M", 1e6), ("k", 1e3)) if step >= d / 10), ("", 1))
    st = step / div
    places = next(d for d in range(7) if abs(round(st, d) - st) < 1e-9 * max(1, st))
    return f"{prefix}{v / div:.{places}f}{unit}"

def fmt_qps(v):
    """Queries per second as Table 1 shows them (fmtN on the page): whole numbers from 100, else two significant
    digits (0.20, 16, 128)."""
    return str(round(v)) if v >= 99.5 else f"{v:#.2g}".rstrip(".")

def fmt_n(v):
    if v >= 1e6: return f"{float(f'{v / 1e6:.2g}'):g}M"
    if v >= 1e3: return f"{float(f'{v / 1e3:.2g}'):g}k"
    return f"{float(f'{v:.2g}'):g}"

# Approximate advance widths of Source Serif 4, in em, for placing labels without a browser.
def text_width(s, size):
    em = 0
    for ch in s:
        if ch in "iljft.,:;'!| ": em += 0.29
        elif ch in "mw": em += 0.80
        elif ch in "MW": em += 0.92
        elif ch.isupper(): em += 0.67
        elif ch.isdigit(): em += 0.53
        else: em += 0.51
    return em * size * 1.04

def ticks(lo, hi, per_decade=1e9):
    """1, 2 and 5 times the powers of ten from 10^lo to 10^hi; only the powers where a decade is under 170 px."""
    for e in range(math.floor(lo), math.ceil(hi) + 1):
        for m in (1, 2, 5) if per_decade >= 170 else (1,):
            v = m * 10 ** e
            if lo - 1e-9 <= math.log10(v) <= hi + 1e-9:
                yield v

def efficiency(p):
    """Queries per second divided by cost: for ranking machines one over price per hour x run time x run time, the
    energy-delay product of chip design with cost in place of energy (methodology, Measures)."""
    return p["qps"] / p["dollars"]

def most_efficient(ps):
    """A system's most efficient machine: the one with the highest efficiency."""
    return max(ps, key=efficiency)

def nice_step(v):
    """A tick step at or above v: 1, 2 or 5 times a power of ten, so that the ticks have short labels."""
    e = 10 ** math.floor(math.log10(v))
    return next(m * e for m in (1, 2, 5, 10) if m * e >= v * (1 - 1e-9))

def hero_svg(sf, W, H, font, mark_s, mark_l, cls, best_only, ylog=True, xlog=True):
    """With best_only, a system shows only its most efficient machine; its other marks, and the line joining them, are
    drawn hidden (class alt), for hovering and selecting. The axes are the same either way. Queries per second on a
    log scale (ylog) or a linear one, from 0, and the cost likewise (xlog); the page switches each axis between the two
    by a click on its title."""
    pts = points(sf)
    by = {}
    for p in pts:
        by.setdefault(p["name"], []).append(p)
    top = {name: most_efficient(ps) for name, ps in by.items()}
    # the Pareto front of all systems on all machines: no cheaper mark answers more queries per second; with best_only
    # a system shows its most efficient machine and those of its machines on the front, the others drawn hidden
    front = []
    for p in sorted(pts, key=lambda p: (p["dollars"], -p["qps"])):
        if not front or p["qps"] > front[-1]["qps"]:
            front.append(p)
    keep = {id(p) for p in front} | {id(p) for p in top.values()}
    shown = [p for p in pts if not best_only or id(p) in keep]
    alt = lambda p: " alt" if best_only and id(p) not in keep else " extra" if best_only and p is not top[p["name"]] else ""
    # every mark the same size, whatever the machine (the middle of mark_s and mark_l)
    size = lambda p: (mark_s + mark_l) / 2
    L, R, T, B = 52, 18, 34, 46
    lx = [math.log10(p["dollars"]) for p in pts]; ly = [math.log10(p["qps"]) for p in pts]
    x0, x1 = math.floor((min(lx) - 0.1) * 2) / 2, math.ceil((max(lx) + 0.1) * 2) / 2
    y0, y1 = math.floor((min(ly) - 0.06) * 2) / 2, math.ceil((max(ly) + 0.06) * 2) / 2
    X = lambda v: L + (math.log10(v) - x0) / (x1 - x0) * (W - L - R)
    Y = lambda v: T + (1 - (math.log10(v) - y0) / (y1 - y0)) * (H - T - B)
    yticks = list(ticks(y0, y1))
    xticks = list(ticks(x0, x1, (W - L - R) / (x1 - x0)))
    if not xlog:  # from $0 to the first round step above the dearest, but at most 1.5 times the dearest of the most
        # efficient machines (a costlier machine of a system falls outside the frame), as many round steps as fit
        most = min(max(p["dollars"] for p in pts), 1.5 * max(p["dollars"] for p in top.values())) * (1 + 24 / (W - L - R))
        xstep = nice_step(most / max(3, (W - L - R) / 110))
        top_x = math.ceil(most / xstep - 1e-9) * xstep
        X = lambda v: L + v / top_x * (W - L - R)
        xticks = [k * xstep for k in range(int(top_x / xstep + 1e-9) + 1)]
    if not ylog:  # from 0 to a round number above the most queries per second, ticks a round step apart
        most = max(p["qps"] for p in pts) * (1 + 24 / (H - T - B))
        step = nice_step(most / max(4, (H - T - B) / 45))
        top_q = math.ceil(most / step - 1e-9) * step
        Y = lambda v: T + (1 - v / top_q) * (H - T - B)
        yticks = [k * step for k in range(int(top_q / step + 1e-9) + 1)]
    o = [f'<svg class="hero-svg {cls} {"y-log" if ylog else "y-lin"} {"x-log" if xlog else "x-lin"}" viewBox="0 0 {W} {H}" data-frame="{L} {T} {W - R} {H - B}" role="img" '
         f'aria-label="Queries per second against the cost of running all queries, scale factor {sf}">']
    for v in xticks:
        o.append(f'<line class="grid" x1="{X(v):.1f}" x2="{X(v):.1f}" y1="{T}" y2="{H - B}"/>'
                 f'<text class="tick" x="{X(v):.1f}" y="{H - B + font + 6}" text-anchor="middle">{fmt_usd(v) if xlog else fmt_step(v, xstep, "$")}</text>')
    for v in yticks:
        o.append(f'<line class="grid" x1="{L}" x2="{W - R}" y1="{Y(v):.1f}" y2="{Y(v):.1f}"/>'
                 f'<text class="tick" x="{L - 9}" y="{Y(v) + font * 0.35:.1f}" text-anchor="end">{fmt_n(v) if ylog else fmt_step(v, step)}</text>')
    o.append(f'<line class="axis" x1="{L}" x2="{W - R}" y1="{H - B}" y2="{H - B}"/>')
    o.append(f'<text class="axt" x="{W - R}" y="{H - 6}" text-anchor="end">cost of running all {NQ} queries <tspan class="xscale">({"log" if xlog else "linear"})</tspan> →</text>')
    o.append(f'<text class="axt" x="{L}" y="{T - 14}">queries per second <tspan class="yscale">({"log" if ylog else "linear"})</tspan> ↑</text>')
    # the marks, their lines and the front stay inside the frame (on a linear cost axis, costlier machines fall outside)
    o.append(f'<clipPath id="frame-{cls}-{sf}-{"best" if best_only else "all"}-{int(xlog)}{int(ylog)}"><rect x="{L}" y="0" width="{W - R - L}" height="{H - B}"/></clipPath>')
    clip = f'clip-path="url(#frame-{cls}-{sf}-{"best" if best_only else "all"}-{int(xlog)}{int(ylog)})"'
    inside = lambda p: X(p["dollars"]) <= W - R
    o.append(f'<g {clip}>')
    # the Pareto front (above), drawn dashed: in either view its marks are all shown
    d = f'M{X(front[0]["dollars"]):.1f},{H - B}'
    for i, p in enumerate(front):
        nx = X(front[i + 1]["dollars"]) if i + 1 < len(front) else W - R
        d += f'L{X(p["dollars"]):.1f},{Y(p["qps"]):.1f}L{nx:.1f},{Y(p["qps"]):.1f}'
    o.append(f'<path class="front" d="{d}"/>')
    for name, ps in by.items():  # a system's machines joined by a line, from the smallest to the largest
        if len(ps) > 1:
            line = " ".join(f'{X(p["dollars"]):.1f},{Y(p["qps"]):.1f}' for p in sorted(ps, key=lambda p: p["rank"]))
            o.append(f'<polyline class="pr s-{name}{" alt" if best_only else ""}" fill="none" points="{line}"/>')
    # Labels: one per system, next to its most efficient mark (in both views), away from the marks and
    # from each other. Every label has its places, each scored on its own: the nearer the text looks, the better,
    # then right of the mark, then level with it. A label goes only where its own system's mark is clearly the nearest, so it cannot be read
    # as another's; where two marks nearly coincide no place is, and then any free place counts, at a high cost.
    # Labels are placed one at a time, each at its best place still free; the order decides who gets the contested
    # places, so many orders are tried and the layout with the lowest total cost wins.
    marks = []
    for p in pts:  # every mark, also those drawn hidden: a hover shows them
        if not inside(p):
            continue
        r = size(p) / 2 + 2
        marks.append((X(p["dollars"]) - r, X(p["dollars"]) + r, Y(p["qps"]) - r, Y(p["qps"]) + r))
    overlap = lambda b, q: b[0] < q[1] and b[1] > q[0] and b[2] < q[3] and b[3] > q[2]
    def hit(b):
        return b[0] < L or b[1] > W - R or b[2] < T or b[3] > H - B or any(overlap(b, q) for q in marks)
    anchors = [(n, top[n]) for n in by]
    anchors = [(n, p if inside(p) else min(by[n], key=lambda q: q["dollars"])) for n, p in anchors]
    anchors = [(n, p) for n, p in anchors if inside(p)]
    # a label may also go next to the system's other marks on the Pareto front (grey in the view of the most efficient
    # machines), at a small cost, so that it needs no line where its most efficient mark is crowded
    marks_of = {n: [p] + [q for q in front if q["name"] == n and q is not p and inside(q)] for n, p in anchors}
    places = {}  # name: [(cost, box, the mark it is next to)], cheapest first
    for name, p in ((n, q) for n, _ in anchors for q in marks_of[n]):
        extra = 0 if p is top[name] else 50
        w, h = text_width(NAMES[name], font) + 2, font + 1
        px, py = X(p["dollars"]), Y(p["qps"])
        g = size(p) / 2 + 3  # the gap between a mark and its label
        def dist(b, cx=px, cy=py):  # from a mark's centre to the nearest point of a label box
            return math.hypot(max(b[0] - cx, 0, cx - b[1]), max(b[2] - cy, 0, cy - b[3]))
        others = [(X(q["dollars"]), Y(q["qps"])) for q in shown if q["name"] != name and inside(q)]
        cands = []
        for dx in range(int(-w - g - 90), int(g + 91), 2):
            for dy in range(int(-h - g - 60), int(g + 61), 2):
                box = (px + dx, px + dx + w, py + dy, py + dy + h)
                d = dist(box)
                if d < g - 1 or hit(box):
                    continue
                # how far the text looks: beside the mark, the gap to it; above or below, the distance to the middle
                # of the word, half counted sideways, so that a label off to one side, or touching the mark only at a
                # corner, counts as farther than a centred one; in steps of 3 px, squared so that one label far off
                # costs more than two a little off
                if box[2] <= py <= box[3]:
                    m = max(box[0] - px, 0, px - box[1])
                else:
                    m = math.hypot((px - (box[0] + box[1]) / 2) / 2, py - (box[2] + box[3]) / 2)
                cost = (max(m - g, 0) // 3) ** 2 * 100 + (0 if dx >= 0 else 10) + abs(dy + h / 2) / 10
                if not all(dist(box, ox, oy) > d + 6 for ox, oy in others):
                    cost += 100000
                cands.append((cost + extra, box, p))
        places[name] = sorted(places.get(name, []) + (cands or [(1e9 + extra, (px + g, px + g + w, py - h / 2, py + h / 2), p)]),
                              key=lambda c: c[0])
    def layout(order):
        put, total = {}, 0
        for name in order:
            c = next((c for c in places[name] if not any(overlap(c[1], q[1]) for q in put.values())), places[name][-1])
            put[name] = c; total += c[0]
        return total, put
    rng = random.Random(sf)  # the same layout on every build
    names = sorted(places, key=lambda n: places[n][0][0])
    best_layout = min((layout(names if k == 0 else rng.sample(names, len(names))) for k in range(300)), key=lambda t: t[0])
    labels = []
    for name, _ in anchors:
        _, pos, p = best_layout[1][name]
        px, py = X(p["dollars"]), Y(p["qps"])
        g = size(p) / 2 + 3
        h = font + 1
        cx, cy = max(pos[0], min(px, pos[1])), max(pos[2], min(py, pos[3]))
        if math.hypot(cx - px, cy - py) > g + 8:
            # the line ends at the middle of the label's near side, or above or below the mark at its top or bottom
            if pos[0] <= px <= pos[1]:
                ex, ey = px, pos[2] - 3 if py < pos[2] else pos[3] + 1
            else:
                ex, ey = (pos[0] - 3 if px < pos[0] else pos[1] + 3), (pos[2] + pos[3]) / 2
            labels.append(f'<line class="leader s-{name}" x1="{px:.1f}" y1="{py:.1f}" x2="{ex:.1f}" y2="{ey:.1f}"/>')
        labels.append(f'<text class="lb hit s-{name}" x="{pos[0]:.1f}" y="{pos[3] - h * 0.22:.1f}" data-tip="{tip(name, by[name])}">{NAMES[name]}</text>')
    for p in pts:
        z = size(p)
        o.append(f'<circle class="halo s-{p["name"]}{alt(p)}" cx="{X(p["dollars"]):.1f}" cy="{Y(p["qps"]):.1f}" r="{z / 2 + 2.5}"/>')
    for p in pts:
        z = size(p)
        o.append(f'<g class="mk s-{p["name"]}{alt(p)}" transform="translate({X(p["dollars"]) - z / 2:.1f},{Y(p["qps"]) - z / 2:.1f}) scale({z / 16:g})">'
                 f'{GLYPHS[p["name"]]}</g>')
    o.append("</g>")
    o += labels
    o.append(f'<g {clip}>')
    for p in pts:
        # the most efficient mark tells about all of the system's machines, which it shows when hovered
        about = sorted(by[p["name"]], key=lambda q: q["rank"]) if best_only else [p]
        o.append(f'<circle class="hit s-{p["name"]}{alt(p)}" cx="{X(p["dollars"]):.1f}" cy="{Y(p["qps"]):.1f}" r="{size(p) / 2 + 5}" '
                 f'data-tip="{tip(p["name"], about, top[p["name"]] if best_only else None)}"/>')
    o.append("</g>")
    return "".join(o) + "</svg>"

def tip(name, ps, best=None):
    """One machine: its numbers in two lines; several: a line each, the most efficient in bold."""
    if len(ps) == 1:
        p = ps[0]
        rows = (f'<div><span class="m">{p["machine"]}</span> {fmt_qps(p["qps"])} q/s · {fmt_usd2(p["dollars"])}</div>'
                f'<div class="m">all {NQ} queries in {p["secs"]:.1f} s</div>')
    else:
        rows = "".join(f'<div{" style=\"font-weight:600\"" if p is best else ""}><span class="m">{p["machine"]}</span> '
                       f'{fmt_qps(p["qps"])} q/s · {fmt_usd2(p["dollars"])}</div>' for p in ps)
        if best:
            rows += '<div class="m">in bold the most efficient (queries per second ÷ cost)</div>'

    return html.escape(f'<div class="t">{NAMES[name]}</div>{rows}<div class="m">{ps[0]["correct"]} of {NQ} correct</div>', quote=True)

def hero():
    """Figure 1 in every view, each a file of its own (out/fig1/<sf>-<best|all>-<x log|lin>-<y log|lin>-<wide|narrow>.svg),
    the page loading a view when it is first shown; the first view (the largest scale factor, the most efficient
    machines, both axes linear), for a large screen and a phone, is in the page itself."""
    d = os.path.join(OUT, "fig1")
    shutil.rmtree(d, ignore_errors=True)
    os.makedirs(d)
    first = f"{DEFAULT_SF}-best-lin-lin"
    inline = ""
    for sf in scale_factors():
        for m in ("best", "all"):
            for xlog in (True, False):
                for ylog in (True, False):
                    key = f"{sf}-{m}-{'log' if xlog else 'lin'}-{'log' if ylog else 'lin'}"
                    for width, args in (("wide", (1000, 540, 15, 15, 22)), ("narrow", (420, 450, 12.5, 12, 17))):
                        svg = hero_svg(sf, *args, f"v-{width}", m == "best", ylog, xlog)
                        open(os.path.join(d, f"{key}-{width}.svg"), "w").write(svg)
                        if key == first:
                            inline += svg
    return f'<div class="hero-plot" id="hero-plot" data-key="{first}">{inline}</div>'

def machine_size(machine):
    """Cores and memory of a machine, as the benchmark configurations that ran on it give them."""
    specs = {(c["threads"], c["memory"]) for c in D["configs"].values() if c["machine"] == machine}
    assert len(specs) == 1, f"{machine}: configurations disagree on threads and memory: {specs}"
    return specs.pop()

def machine_spec(machine):
    threads, memory = machine_size(machine)
    return f"{threads} {'core' if threads == 1 else 'cores'}", re.sub(r"(\d)([A-Z])", r"\1 \2", memory)

def price_h(machine):
    """USD per hour: the list price of the AWS instance."""
    assert machine in PRICE_H, f"{machine}: no price in PRICE_H"
    return PRICE_H[machine]

def machine_order(machine):
    return (machine_size(machine)[0], price_h(machine))

def sf_machines(sf):
    return sorted({c["machine"] for c in D["configs"].values() if c["sf"] == sf}, key=machine_order)

def hero_machines():
    """Caption text naming the machines behind the marks, one per scale factor."""
    out = []
    for sf in sorted({c["sf"] for c in D["configs"].values()}):
        ms = sf_machines(sf)
        name = lambda m: f"{m} ({', '.join(machine_spec(m))})"
        if len(ms) == 1:
            out.append(f'<span class="hero-cap sf-{sf}">Every system on {name(ms[0])}.</span>')
            continue
        best = note("efficient", "Efficiency is queries per second (y-axis) divided by cost (x-axis). A system is efficient "
                    "when it answers quickly without needing an expensive machine to do it (see Methodology). Hover over a "
                    "system, or select it, to see its other machines.")
        out.append(f'<span class="hero-cap m-best sf-{sf}">Each system on its most {best} configuration; in grey, its other '
                   f'configurations on the Pareto front (dashed).</span>')
        out.append(f'<span class="hero-cap m-all sf-{sf}">Each system on every '
                   f'{note("configuration", f"{len(ms)} machines at this scale factor, from {name(ms[0])} to {name(ms[-1])}.")}, joined by a line.</span>')
    return "".join(out)

def machines():
    return sorted({c["machine"] for c in D["configs"].values()}, key=machine_order)

def note(text, note):
    """Text with a hover note: dashed underline, the note on hover, focus or tap."""
    return f'<span class="hn" tabindex="0" data-note="{html.escape(note, quote=True)}">{text}</span>'

def price_note():
    """How the prices of the start page were set, as the note of Figure 1's caption."""
    return "AWS on-demand prices of the instances."

# The server the results run on, in words: the processor's generation and clock, and how one of its cores compares
# with a vCPU of c8a (AMD EPYC 9005, Zen 5, up to 4.5 GHz, one physical core per vCPU); the systems' run records give
# its threads, memory and kernel. The EPYC 9745 is Zen 5c: the cores of c8a's generation, made smaller, at a lower clock.
SERVER = ("an AMD EPYC 9745 (Zen 5c, up to 3.7 GHz)", 128,
          "its cores are Zen 5c, the cores of c8a’s generation made smaller and run at a lower clock, so we expect a "
          "core to be somewhat slower than a c8a vCPU")

# DuckDB on every configuration, on the c8a instances themselves (us-east-2, the same image and settings) and on the
# server, 20 October 2026: (scale factor, machine, the queries both answered correctly, the time of the last run over
# them on c8a, on the server, in seconds)
HOST_COMPARISON = [
    (1, "c8a.medium", 409, 2.642, 3.122), (1, "c8a.large", 409, 2.607, 2.690), (1, "c8a.xlarge", 409, 2.370, 2.621),
    (1, "c8a.2xlarge", 409, 2.284, 2.651), (10, "c8a.xlarge", 408, 8.588, 9.651), (10, "c8a.2xlarge", 408, 7.006, 8.217),
    (10, "c8a.4xlarge", 408, 7.191, 7.938), (10, "c8a.8xlarge", 408, 7.413, 8.472), (100, "c8a.4xlarge", 408, 33.393, 37.300),
    (100, "c8a.8xlarge", 408, 28.159, 32.133), (100, "c8a.12xlarge", 408, 27.349, 31.346), (100, "c8a.16xlarge", 408, 27.763, 31.430),
    (100, "c8a.24xlarge", 408, 28.634, 32.804), (1000, "c8a.12xlarge", 407, 201.566, 215.411), (1000, "c8a.16xlarge", 407, 181.663, 200.361),
    (1000, "c8a.24xlarge", 407, 177.729, 192.511),
]

def host_comparison():
    """DuckDB on the instances and on the server, configuration by configuration (HOST_COMPARISON), as a paragraph
    and a table."""
    ratios = [o / a for _, _, _, a, o in HOST_COMPARISON]
    rows = "".join(f'<tr><td class="r">{sf}</td><td>{machine}</td><td class="r">{n}</td><td class="r">{a:.1f}&#8202;s</td>'
                   f'<td class="r">{o:.1f}&#8202;s</td><td class="r">{o / a:.2f}</td></tr>' for sf, machine, n, a, o in HOST_COMPARISON)
    mean = math.exp(sum(map(math.log, ratios)) / len(ratios))
    return (f'<p><b>How close the server is to the instances.</b> DuckDB ran every configuration both on the server '
            f'and on the c8a instances themselves (us-east-2, the same image and settings). The table gives the time of '
            f'the last run, over the queries both answered correctly. On the server the queries of a configuration '
            f'take {min(ratios):.2f} to {max(ratios):.2f} times as long as on the instance, {mean:.2f} times in the '
            f'geometric mean. We expect that the systems’ query times are roughly {100 * (mean - 1):.0f}% slower on '
            f'the local server than they would be on AWS.</p>'
            '<table class="spec"><thead><tr><th class="r">Scale</th><th>Machine</th><th class="r">Queries</th>'
            '<th class="r">c8a</th><th class="r">Server</th><th class="r">Ratio</th></tr></thead>'
            f'<tbody>{rows}</tbody></table>')

def machines_text():
    """The methodology's paragraphs on the machines, the server that runs them, and their prices."""
    cpu, cores, per_core = SERVER
    records = glob.glob(os.path.join(ROOT, "systems", "*", "results", "*", "*.json"))
    hosts = {json.dumps(json.load(open(f))["host"], sort_keys=True) for f in records}
    assert len(hosts) == 1, f"the results ran on several servers: {hosts}"
    host = json.loads(hosts.pop())
    assert all(c["threads"] <= cores for c in D["configs"].values()), "a configuration has more vCPUs than the server has cores"
    return ('<p>Every system runs on every machine configuration of its scale factor below: pinned to that many '
            'hardware threads and limited to that much memory, everything included. The configurations are AWS c8a '
            'instances.</p>'
            + machines_table()
            + '<p class="spec-note">AWS instances are priced on demand, Linux, us-east-1.</p>'
            + f'<p><b>All runs are on one server</b> standing in for the instances: {cpu}, {cores} cores with '
            f'{host["cpus"]} hardware threads, and {host["memory_bytes"] / 2**30:.0f} GiB of DDR5 memory, under Linux '
            f'{host["kernel"]}. A configuration gets the first hardware threads of the server and the memory of the '
            f'instance. A vCPU of c8a is a physical core; {per_core}. Every thread has a core of its own, as on c8a, '
            f'and the smaller configurations likely get more of the cache and memory bandwidth than an instance of '
            f'their size.</p>'
            + host_comparison())

def example_run():
    """A run command for one configuration of the results, as the reproduce section shows it."""
    c = min(D["configs"].items(), key=lambda kv: (kv[1]["sf"], machine_order(kv[1]["machine"])))
    return f'./target/release/dbo-bench run --benchmark {c[1]["benchmark"]} --system duckdb --config {c[0]}'

# What every system is and how it runs; the name shown where its results recorded no version.
SYSTEM_INFO = {
    "duckdb": ("DuckDB", "embedded"),
    "hyper": ("Hyper", "Tableau's engine, its own server"),
    "hardcharger": ("Hardcharger", "DuckDB behind a Warp SQL server, queried through its CLI"),
    "cedardb": ("CedarDB", "its own server"),
    "umbra": ("Umbra", "its own server"),
    "pg_duckdb": ("pg_duckdb on PostgreSQL", "PostgreSQL tables, DuckDB runs the queries"),
    "postgres": ("PostgreSQL", "its own server"),
    "datafusion": ("DataFusion", "embedded, queries the Parquet files in place"),
    "firebolt": ("Firebolt Core", "its own server"),
    "clickhouse": ("ClickHouse", "its own server"),
    "chdb": ("chDB", "ClickHouse as a library, embedded"),
    "pg_clickhouse": ("pg_clickhouse on PostgreSQL", "PostgreSQL passes the queries to ClickHouse"),
    "pg_brew": ("Querybrew on PostgreSQL", "Umbra writes every query for PostgreSQL, which runs it"),
    "clickhouse_brew": ("Querybrew on ClickHouse", "Umbra writes every query for ClickHouse, which runs it"),
}

PAGES = [("index", "Results", "index.html"), ("queries", "Queries", "queries/index.html"),
         ("methodology", "Methodology", "methodology.html"), ("add-a-system", "Add a system", "add-a-system.html")]

# Light or dark: the system's by default; the button in the top line switches to the other and remembers it (in the
# browser's storage), and switching back to the system's forgets it again. The choice is applied in the head, before
# the page is drawn. Pages that paint canvases redraw on the event "themechange".
THEME_HEAD = ('<script>try { const t = localStorage.getItem("theme"); if (t) document.documentElement.dataset.theme = t; } '
              'catch (e) {}</script>')
MOON = '<svg viewBox="0 0 16 16" width="15" height="15" aria-hidden="true"><path d="M10.6 1.8a6.3 6.3 0 1 0 3.6 9.6A5.2 5.2 0 0 1 10.6 1.8z" fill="currentColor"/></svg>'
SUN = ('<svg viewBox="0 0 16 16" width="15" height="15" aria-hidden="true"><circle cx="8" cy="8" r="3.2" fill="currentColor"/>'
       + "".join(f'<rect x="7.3" y="0.6" width="1.4" height="2.6" rx="0.7" fill="currentColor" transform="rotate({k * 45} 8 8)"/>' for k in range(8))
       + "</svg>")
# The repository, linked from the top line, left of the theme button
GITHUB = "https://github.com/dbolympics/dbolympics"
GITHUB_MARK = ('<svg viewBox="0 0 16 16" width="15" height="15" aria-hidden="true"><path fill="currentColor" d="M8 0c4.42 0 8 3.58 8 8a8.013 8.013 0 0 1-5.45 7.59c-.4.08-.55-.17-.55-.38 0-.27.01-1.13.01-2.2 0-.75-.25-1.23-.54-1.48 1.78-.2 3.65-.88 3.65-3.95 0-.88-.31-1.59-.82-2.15.08-.2.36-1.02-.08-2.12 0 0-.67-.22-2.2.82-.64-.18-1.32-.27-2-.27-.68 0-1.36.09-2 .27-1.53-1.03-2.2-.82-2.2-.82-.44 1.1-.16 1.92-.08 2.12-.51.56-.82 1.28-.82 2.15 0 3.06 1.86 3.75 3.64 3.95-.23.2-.44.55-.51 1.07-.46.21-1.61.55-2.33-.66-.15-.24-.6-.83-1.23-.82-.67.01-.27.38.01.53.34.19.73.9.82 1.13.16.45.68 1.31 2.69.94 0 .67.01 1.3.01 1.49 0 .21-.15.45-.55.38A7.995 7.995 0 0 1 0 8c0-4.42 3.58-8 8-8Z"/></svg>')
THEME_SCRIPT = """<script>(() => {
  const root = document.documentElement, b = document.getElementById("theme"), sys = matchMedia("(prefers-color-scheme: dark)");
  const dark = () => root.dataset.theme ? root.dataset.theme === "dark" : sys.matches;
  const show = () => { const d = dark(); b.innerHTML = d ? SUN : MOON; b.title = d ? "Light" : "Dark"; b.setAttribute("aria-label", d ? "Switch to light" : "Switch to dark"); };
  b.onclick = () => {
    const t = dark() ? "light" : "dark";
    if (t === (sys.matches ? "dark" : "light")) { delete root.dataset.theme; try { localStorage.removeItem("theme"); } catch (e) {} }
    else { root.dataset.theme = t; try { localStorage.setItem("theme", t); } catch (e) {} }
    show(); dispatchEvent(new Event("themechange"));
  };
  sys.addEventListener("change", show); show();
})();</script>""".replace("SUN", json.dumps(SUN)).replace("MOON", json.dumps(MOON))

def head_extra(up=""):
    """What every page's head holds besides its own: the theme choice and the icon."""
    return f'{THEME_HEAD}\n<link rel="icon" href="{up}favicon.svg" type="image/svg+xml">\n<link rel="apple-touch-icon" href="{up}apple-touch-icon.png">'

def favicon_svg():
    """The logo as the browser's icon: square, thicker lines for 16 px, dark on light and light on dark."""
    s = logo(64)
    m = re.search(r'viewBox="0 ([-\d.]+) 44 ([\d.]+)"', s)
    top, h = float(m.group(1)), float(m.group(2))
    s = re.sub(r'<svg [^>]*>', f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="{(44 - h) / 2:g} {top:g} {h:g} {h:g}">'
               '<style>.d{fill:#fff;stroke:#1b1b1a;stroke-width:3}@media (prefers-color-scheme: dark){.d{fill:#151514;stroke:#ecebe5}}</style>', s, count=1)
    return s.replace('fill="var(--paper)" stroke="currentColor" stroke-width="1.6"', 'class="d"')

def topbar(current, up=""):
    """The line at the top of a page: the way home (not on the start page) and the pages, the current one not a link.
    `up` leads from the page to the site's root (e.g. "../")."""
    links = "".join(f'<span class="here">{label}</span>' if key == current else f'<a href="{up}{href}">{label}</a>'
                    for key, label, href in PAGES)
    home = "" if current == "index" else f'<a class="crumb" href="{up}index.html">{logo(26)}<b>DB Olympics</b></a>'
    github = f'<a class="github" href="{GITHUB}" title="GitHub" aria-label="The repository on GitHub">{GITHUB_MARK}</a>'
    toggle = f'{github}<button class="theme" id="theme" type="button"></button>{THEME_SCRIPT}'
    return f'<div class="topbar{" home" if current == "index" else ""}">{home}<nav class="topnav" aria-label="Pages">{links}{toggle}</nav></div>'

def glyph_svg(name, size):
    return f'<svg class="glyph" viewBox="0 0 16 16" width="{size}" height="{size}" aria-hidden="true">{GLYPHS[name]}</svg>'

def system_version(name):
    """The versions the system reported in its results (its system file's version query), joined if runs differ;
    None if no run recorded one."""
    vs = sorted({v for c in D["configs"].values() if name in c["systems"] for v in [c["systems"][name].get("version")] if v})
    return " / ".join(vs) if vs else None

def systems_table():
    # the systems with results
    shown = [n for n in NAMES if any(n in c["systems"] for c in D["configs"].values())]
    rows = "".join(f'<tr><td>{glyph_svg(n, 13)}{NAMES[n]}</td><td>{html.escape(system_version(n) or SYSTEM_INFO[n][0])}</td><td class="hide-s">{SYSTEM_INFO[n][1]}</td></tr>'
                   for n in shown)
    # a note only where a system shows its name instead of a version
    note = ('<p class="measure"><small>No version number is shown if the run did not record any.</small></p>'
            if any(system_version(n) is None for n in shown) else "")
    return ('<table class="spec"><thead><tr><th>System</th><th>Version</th><th class="hide-s">How it runs</th></tr></thead>'
            f'<tbody>{rows}</tbody></table>{note}')

def machines_table():
    used = {}
    for c in D["configs"].values():
        used.setdefault(c["machine"], []).append(c["sf"])
    # the cores as a number: the column says what they are
    rows = "".join(f'<tr><td>{m}</td><td class="r">{machine_size(m)[0]}</td><td class="r">{machine_spec(m)[1]}</td>'
                   f'<td class="r">${price_h(m):.4f}</td><td class="r">{", ".join(str(s) for s in sorted(used[m]))}</td></tr>'
                   for m in sorted(used, key=machine_order))
    return ('<table class="spec"><thead><tr><th>Machine</th><th class="r">Cores</th><th class="r">Memory</th>'
            f'<th class="r">Per hour</th><th class="r">Scale factors</th></tr></thead><tbody>{rows}</tbody></table>')

# the assistant that built the benchmark, by its commits, for a copy without them
WRITER = "Claude Opus 5.5"

def ai_facts():
    """Which models the role play and the repository record: the agents' model from the transcripts, the assistant
    that built the benchmark from the commit history (the most frequent co-author)."""
    import subprocess
    root = ROOT
    run = json.load(open(os.path.join(root, "workload", "catalog.json")))["runs"][0]
    models = set()
    for d, _, files in os.walk(os.path.join(root, "runs")):
        if os.path.basename(d) == "transcripts":
            for f in files:
                models |= set(re.findall(r'"model": ?"(claude-[^"]+)"', open(os.path.join(d, f)).read()))
    assert len(models) == 1, f"the transcripts name several models: {models}"
    def pretty(model_id):  # claude-sonnet-5 -> Claude Sonnet 5, claude-opus-5-5 -> Claude Opus 5.5
        words = model_id.split("-")
        version = ".".join(w for w in words if w.isdigit())
        return " ".join(w.capitalize() for w in words if not w.isdigit()) + (f" {version}" if version else "")
    log = subprocess.run(["git", "-C", root, "log", "--format=%x00%b"], capture_output=True, text=True, check=True).stdout
    commits = [c for c in log.split("\x00")[1:]]
    co = {}
    for c in commits:
        for m in set(re.findall(r"Co-Authored-By: (Claude [^<]+?) <", c)):
            co[m] = co.get(m, 0) + 1
    # without the history (a copy in one commit): the assistant of the history it was made from
    writer = max(co.items(), key=lambda kv: kv[1])[0] if co else WRITER
    return {"agents": pretty(models.pop()), "writer": writer}

# What every customization point means, in plain words (the points themselves come from the runner)
POINT_MEANING = {
    "date_diff_days": "the days from a to b; the difference of two dates is a number of days in PostgreSQL and an interval in the standard",
    "year_month": "a timestamp as a 'YYYY-MM' string",
    "fetch_first": "the first n rows (the standard's FETCH FIRST n ROWS ONLY)",
    "bool_or": "whether any value is true (PostgreSQL's aggregate)",
    "percentile_cont": "the p-th percentile of x, interpolated between the closest values",
    "percentile_cont_filter": "the same, over the rows that meet a condition",
    "string_agg_sorted": "the values of x joined with a separator, in their order (PostgreSQL's STRING_AGG)",
    "string_agg_distinct_sorted": "the same, each value once",
    "count_distinct_pair": "the number of distinct pairs (a, b)",
    "equals_any": "whether an array column contains x; the queries said PostgreSQL's = ANY(array), the default is the standard's membership test",
    "seconds_between": "the seconds from a to b, exactly (PostgreSQL's EXTRACT(EPOCH ...))",
    "count_distinct_over": "the number of distinct values of x in a window",
    "add_minutes": "a timestamp plus n minutes; the default is the standard's interval, which of the four most used databases only PostgreSQL supports",
    "whole_days_between": "the whole days from a to b, two timestamps (PostgreSQL's day field of their difference)",
    "timestamp_midpoint": "the timestamp halfway between a and b",
}

def dialects_section():
    """The customization points, their default spelling, and which systems spell them differently."""
    import subprocess, tomllib
    binary = os.path.join(ROOT, "target", "release", "dbo-bench")
    points = json.loads(subprocess.run([binary, "points"], capture_output=True, text=True, check=True).stdout)
    missing = [p["name"] for p in points if p["name"] not in POINT_MEANING]
    assert not missing, f"add a plain meaning to POINT_MEANING for {missing}"
    systems = [n for n in NAMES if any(n in c["systems"] for c in D["configs"].values())]
    spelled = {}
    for n in systems:
        f = tomllib.load(open(os.path.join(ROOT, "systems", n, "system.toml"), "rb")).get("dialect", {}).get("functions", {})
        for sig, tpl in f.items():
            spelled.setdefault(sig.split("(")[0].strip(), {}).setdefault(tpl, []).append(n)
    rows = []
    for p in points:
        sig = f'{p["name"]}({", ".join(p["params"])})'
        others = spelled.get(p["name"], {})
        diff = "".join(f'<li><span class="who">{", ".join(NAMES[n] for n in ns)}</span><code>{html.escape(t)}</code></li>' for t, ns in others.items())
        rows.append(f'<div class="point"><code class="sig">{html.escape(sig)}</code><p>{html.escape(POINT_MEANING[p["name"]])}.</p>'
                    f'<p class="std"><span class="who">Default</span><code>{html.escape(" ".join(p["default"].split()))}</code></p>'
                    + (f'<ul>{diff}</ul>' if diff else "") + "</div>")
    plain = [NAMES[n] for n in systems if not any(n in ns for v in spelled.values() for ns in v.values())]
    return ("".join(rows) + (f'<p class="measure">{", ".join(plain)} use the standard spelling everywhere.</p>' if plain else ""))

def scale_factors():
    return sorted({c["sf"] for c in D["configs"].values()})

def sf_buttons():
    # a scale factor is about 1 GB of CSV per unit
    return "".join(f'<button class="opt" data-sf="{sf}">{sf} GB</button>' for sf in scale_factors())

def hero_css():
    rules = [" ".join(f'.hero[data-sf="{sf}"] .hero-cap:not(.sf-{sf}) {{ display: none; }}' for sf in scale_factors()),".hero[data-sel] .mk { color: var(--rule-strong); } .hero[data-sel] .lb { fill: var(--muted); }",
             ".hero-svg .hit { cursor: pointer; } .hero-svg .alt { visibility: hidden; }"]
    for n in NAMES:
        rules.append(f'.hero[data-sel="{n}"] .mk.s-{n} {{ color: var(--accent); }}'
                     f'.hero[data-sel="{n}"] .lb.s-{n} {{ fill: var(--accent); font-weight: 600; }}'
                     f'.hero[data-sel="{n}"] :is(.pr.s-{n}, .leader.s-{n}) {{ stroke: var(--accent); stroke-width: 1.6; }}')
        rules.append(f'.hero[data-sel="{n}"] .alt.s-{n}, .hero svg:has(.hit.s-{n}:hover) .alt.s-{n} {{ visibility: visible; }}')
        rules.append(f'.hero svg:has(.hit.s-{n}:hover) :is(.mk.s-{n}) {{ color: var(--accent); }}'
                     f'.hero svg:has(.hit.s-{n}:hover) :is(.lb.s-{n}) {{ fill: var(--accent); font-weight: 600; }}'
                     f'.hero svg:has(.hit.s-{n}:hover) :is(.pr.s-{n}, .leader.s-{n}) {{ stroke: var(--accent); stroke-width: 1.6; }}')
    return "\n".join(rules)

def fmt_s(v):
    return f"{v:g}\u202fs"

def timeouts_text():
    """The timeout of every scale factor: 5 s, or 5 s at SF1 and SF10, 50 s at SF100."""
    by = {}
    for c in D["configs"].values():
        by.setdefault(c["timeout"], set()).add(c["sf"])
    if len(by) == 1:
        return fmt_s(next(iter(by)))
    sfs = lambda s: " and ".join(f"SF{x}" for x in sorted(s)) if len(s) < 3 else ", ".join(f"SF{x}" for x in sorted(s))
    return ", ".join(f"{fmt_s(t)} at {sfs(s)}" for t, s in sorted(by.items(), key=lambda kv: min(kv[1])))

def reps_text(words):
    """How often every query runs after a load, in `words` (1: "once", or 1: "one")."""
    n = one("reps")
    return words.get(n, f"{n} times")

NUMBERS = {1: "one", 2: "two", 3: "three"}

def one(key):
    """The value of a configuration field when all configurations share it."""
    vals = {c[key] for c in D["configs"].values()}
    assert len(vals) == 1, f"configurations differ in {key}: {vals}; the page text assumes one value"
    return vals.pop()

# in the stylesheet's URL, so that a browser never keeps an old one next to a new page
STYLE_VERSION = hashlib.sha1(open(os.path.join(HERE, "style.css"), "rb").read()).hexdigest()[:10]

# The start page's sections after the first, in order, and whether each is shown. One that is not is left out of the
# page (its markup between <!--SECTION:name--> and <!--/SECTION:name--> in the templates); its script stays and draws
# nothing. The shown ones are numbered from 2, each section's figure with its number, and "Methodology" last.
# Left out for now: the runtime distribution and the growth over the loads; "System against system" (two systems,
# every query by the factor between them), since the queries' figure ordered by a system's time shows much the same.
SHOW = {"distribution": False, "queries": True, "versus": False, "growth": False}
SEC = {name: str(n) for n, name in enumerate([n for n, shown in SHOW.items() if shown] + ["method"], 2)}

def main():
    SUBS = {
        "<!--LOGO-->": logo(64),
        "<!--HERO-->": hero(),
        "<!--HERO_MACHINES-->": hero_machines(),
        "<!--SF_BUTTONS-->": sf_buttons(),
        **{f"{{{{SEC_{name.upper()}}}}}": n for name, n in SEC.items()},
        "<!--HEAD-->": head_extra(),
        "<!--SYSTEMS-->": systems_table(),
        "<!--MACHINES_TEXT-->": machines_text(),
        "<!--PRICE_NOTE-->": html.escape(price_note(), quote=True),
        "{{EXAMPLE_RUN}}": example_run(),
        "<!--DIALECTS-->": dialects_section(),
        "/*HERO_CSS*/": hero_css(),
        "/*GLYPHS*/": json.dumps(GLYPHS),
        "/*NAMES*/": json.dumps(NAMES),
        "/*PRICES*/": json.dumps({m: price_h(m) for m in machines()}),
        "/*DEFAULT_SF*/": str(DEFAULT_SF),
        "{{GITHUB}}": GITHUB,
        'href="style.css"': f'href="style.css?v={STYLE_VERSION}"',
        "/*DATA_VERSION*/": hashlib.sha1(open(os.path.join(OUT, "data.js"), "rb").read()).hexdigest()[:10],
        "{{TIMEOUT}}": timeouts_text(),
        "{{REPS}}": reps_text({1: "once", 2: "twice", 3: "three times"}),
        "{{REPS_COUNTS}}": "Every query runs once after a load, and that time counts." if one("reps") == 1
                           else f"The median of the {NUMBERS.get(one('reps'), one('reps'))} repetitions counts.",
        **{f"{{{{AI_{k.upper()}}}}}": str(v) for k, v in ai_facts().items()},
    }

    shutil.copy(os.path.join(HERE, "style.css"), OUT)
    open(os.path.join(OUT, "favicon.svg"), "w").write(favicon_svg())
    # a PNG for iOS's home screen, which takes no SVG
    subprocess.run(["magick", "-background", "white", "-density", "600", os.path.join(OUT, "favicon.svg"), "-resize", "136x136",
                    "-gravity", "center", "-extent", "180x180", os.path.join(OUT, "apple-touch-icon.png")], check=True, capture_output=True)
    shutil.copytree(os.path.join(HERE, "fonts"), os.path.join(OUT, "fonts"), dirs_exist_ok=True)
    for src, dst in (("index.template.html", "index.html"), ("methodology.template.html", "methodology.html"), ("add-a-system.template.html", "add-a-system.html")):
        page = open(os.path.join(HERE, src)).read().replace("<!--TOPBAR-->", topbar(dst[:-5]))
        # the sections switched off (SHOW) left out
        page = re.sub(r"<!--SECTION:(\w+)-->\n?(.*?)<!--/SECTION:\1-->\n?", lambda m: m.group(2) if SHOW[m.group(1)] else "",
                      page, flags=re.S)
        for key, val in SUBS.items():
            page = page.replace(key, val)
        assert "{{" not in page and not re.search(r"<!--[A-Z_]+-->|/\*[A-Z_]+\*/", page), f"{src}: a placeholder is left"
        open(os.path.join(OUT, dst), "w").write(page)
        print(f"{dst}: {len(page) / 1024:.0f} KiB")


if __name__ == "__main__":
    main()
