"""What the benchmark bot (tools/bot/bot.py) and the pull requests' check (tools/bot/check_pr.py) share: which
systems a pull request changes, whether the bot may run it, the bot's results commit, and the results' summary.
See docs/BOT.md."""
import csv
import hashlib
import io
import math
import re
import subprocess

# The bot's results commit: one commit, the last of the pull request, only files in systems/<name>/results/, with
#   DB-Olympics-Results: <system> ...           the systems it has results of
#   Benchmarked-System: <system> <code hash>    per system, the code its results are of (code_hash)
#   Approved-By: <login>                        the maintainer who started the run
RESULTS_TRAILER = "DB-Olympics-Results"
SYSTEM_TRAILER = "Benchmarked-System"
APPROVED_TRAILER = "Approved-By"

RESULTS_PATH = re.compile(r"^systems/[^/]+/results/")
SYSTEM_PATH = re.compile(r"^systems/([^/]+)/")
SYSTEM_NAME = re.compile(r"^[a-z0-9][a-z0-9_-]*$")
# Files a pull request may change, besides its systems, for the bot to run it: none of them runs on the host. The bot
# runs the pull request's systems on main (run_tree): a change to anything else (the runner, the generator, the
# queries, the schema, the shared systems/dbo, Cargo's files) would not be in the run.
NOT_RUN = re.compile(r"^(docs/|site/|\.github/)|\.md$|^LICENSE$")
SHARED = "dbo"  # systems/dbo: the library every system's query program uses, not a system
# a system's files (systems/README.md); logo.svg is optional
SYSTEM_FILES = {"system.toml": "100644", "install": "100755", "start": "100755", "stop": "100755", "query.rs": "100644"}


def git(repo, *args, env=None, input=None):
    return subprocess.run(["git", "-C", str(repo), *args], capture_output=True, text=True, check=True, env=env,
                          input=input).stdout.strip()


def trailers(repo, rev):
    """The commit's trailers, as (key, value) pairs."""
    out = git(repo, "log", "-1", "--format=%(trailers:only,unfold)", rev)
    return [tuple(s.strip() for s in line.split(":", 1)) for line in out.splitlines() if ":" in line]


def is_results_commit(repo, rev):
    """A commit of the bot's: its trailer, one parent, and nothing but results."""
    if RESULTS_TRAILER not in dict(trailers(repo, rev)) or len(git(repo, "rev-list", "--parents", "-n1", rev).split()) != 2:
        return False
    files = git(repo, "diff-tree", "--no-commit-id", "-r", "--name-only", rev).splitlines()
    return bool(files) and all(RESULTS_PATH.match(f) for f in files)


def split(repo, main, head):
    """A pull request's commits since main: (the merge base, the results commits, the last commit that is not one
    of them). The results commits are found anywhere, so that they can be moved to the end again."""
    base = git(repo, "merge-base", main, head)
    commits = git(repo, "rev-list", "--reverse", "--topo-order", f"{base}..{head}").splitlines()
    results = [c for c in commits if is_results_commit(repo, c)]
    tip = head
    while tip in results:
        tip = git(repo, "rev-parse", f"{tip}^")
    return base, results, tip


def code_hash(repo, rev, system):
    """The code of a system at a commit: a hash of its files, without its results. None if it has none."""
    listing = [line for line in git(repo, "ls-tree", "-r", rev, "--", f"systems/{system}/").splitlines()
               if not RESULTS_PATH.match(line.split("\t", 1)[1])]
    return hashlib.sha1("\n".join(listing).encode()).hexdigest() if listing else None


def benchmarked(repo, results_commit):
    """{system: code hash} of a results commit."""
    return dict(v.split() for k, v in trailers(repo, results_commit) if k == SYSTEM_TRAILER and len(v.split()) == 2)


def stale(repo, results_commit, tip):
    """The systems whose code at `tip` is not the code the results commit has results of."""
    return sorted(s for s, h in benchmarked(repo, results_commit).items() if code_hash(repo, tip, s) != h)


def changed_systems(repo, base, tip):
    """The systems whose code the pull request changes (since the merge base), and whether it changes systems/dbo."""
    names = {m.group(1) for f in git(repo, "diff", "--name-only", base, tip).splitlines()
             if (m := SYSTEM_PATH.match(f)) and not RESULTS_PATH.match(f)}
    return sorted(names - {SHARED}), SHARED in names


def problems(repo, main, base, tip, own=False):
    """Why the bot must not run the pull request's tip, as (error, sentence) pairs; none if it may. An error is
    wrong in any pull request; the rest only keeps the bot from running it:
    - from a fork: the pull request changes a file that runs on the host (not NOT_RUN, not a system's directory): the
      bot runs the systems on main's, so the change would not be in the run;
    - from a fork: main changed one of the pull request's systems since the merge base: the run would leave that
      change out;
    - from a branch of the repository itself (`own`, pushed by a maintainer): the pull request and main do not merge
      without conflicts, so there is no tree to run (run_tree);
    - a system's directory has a symbolic link or a submodule, or a name that is not a plain one (errors).
    What main changed elsewhere since the merge base is no reason: the run has it. Results the pull request changes
    itself are none either: the bot's results commit undoes them (user_results)."""
    out = []
    systems, _ = changed_systems(repo, base, tip)
    if own:
        if merged_tree(repo, main, tip) is None:
            out.append((False, "The pull request does not merge into main without conflicts: rebase it onto main."))
    else:
        outside = [f for f in git(repo, "diff", "--name-only", base, tip).splitlines()
                   if not NOT_RUN.search(f) and not ((m := SYSTEM_PATH.match(f)) and m.group(1) != SHARED)]
        if outside:
            out.append((False, "The pull request changes files that run outside the containers: "
                       + ", ".join(f"`{f}`" for f in outside[:20]) + (" ..." if len(outside) > 20 else "")
                       + ". From a fork, the bot runs the systems on main's runner, so keep these changes for a "
                       "separate pull request."))
        if both := sorted(set(systems) & set(changed_systems(repo, base, main)[0])):
            out.append((False, f"Main changed {', '.join(f'`systems/{s}`' for s in both)} since the pull request branched off, "
                       "and the run would leave that out: rebase the pull request onto main."))
    for s in systems:
        if not SYSTEM_NAME.match(s):
            out.append((True, f"`systems/{s}`: a system's name has lower-case letters, digits, `-` and `_` only."))
            continue
        for line in git(repo, "ls-tree", "-r", tip, "--", f"systems/{s}/").splitlines():
            mode, path = line.split()[0], line.split("\t", 1)[1]
            if mode in ("120000", "160000"):
                out.append((True, f"`{path}` is a {'symbolic link' if mode == '120000' else 'submodule'}; a system has plain files only."))
    return out


def merged_tree(repo, main, tip):
    """The tree of the pull request merged into main, None if they conflict."""
    r = subprocess.run(["git", "-C", str(repo), "merge-tree", "--write-tree", "--no-messages", main, tip],
                       capture_output=True, text=True)
    return r.stdout.split()[0] if r.returncode == 0 else None


def run_tree(repo, main, base, tip, env, own=False):
    """The tree the bot runs a pull request in, the results as on main. From a branch of the repository itself
    (`own`): the pull request merged into main, its runner, queries and everything else included. From a fork:
    main's, with the directories of the systems the pull request changes as they are at its tip. The index of
    $GIT_INDEX_FILE (in `env`) is used for it."""
    if own:
        git(repo, "read-tree", merged_tree(repo, main, tip), env=env)
        lines = []
        for line in git(repo, "diff-index", "--cached", "-r", main, "--", "systems/", env=env).splitlines():
            meta, path = line.split("\t", 1)
            if RESULTS_PATH.match(path):
                mode, blob = meta.split()[0].lstrip(":"), meta.split()[2]  # main's side
                lines.append(f"{mode} {blob}\t{path}\n" if mode != "000000" else f"0 {'0' * 40}\t{path}\n")
        if lines:
            git(repo, "update-index", "--index-info", env=env, input="".join(lines))
        return git(repo, "write-tree", env=env)
    git(repo, "read-tree", main, env=env)
    systems, _ = changed_systems(repo, base, tip)
    entries = lambda rev, s: {line.split("\t", 1)[1]: line.split()[:3] for line in git(repo, "ls-tree", "-r", rev, "--", f"systems/{s}/").splitlines()
                              if not RESULTS_PATH.match(line.split("\t", 1)[1])}
    lines = []
    for s in systems:
        theirs = entries(tip, s)
        lines += [f"0 {'0' * 40}\t{p}\n" for p in entries(main, s) if p not in theirs]  # removed in the pull request
        lines += [f"{mode} {blob}\t{p}\n" for p, (mode, _, blob) in theirs.items()]
    if lines:
        git(repo, "update-index", "--index-info", env=env, input="".join(lines))
    return git(repo, "write-tree", env=env)


# Why a pull request from a fork of an organization cannot have the bot's results: the bot pushes its results commit to
# the pull request's branch, which "Allow edits by maintainers" lets us do only in a fork of a user's.
ORGANIZATION_FORK = ("The pull request comes from a fork of an organization, whose branch GitHub does not let us push the "
                     "benchmark's results to. Open it from a fork of a user's account instead (with \"Allow edits by "
                     "maintainers\").")


def user_results(repo, base, rev):
    """The results files that differ between the merge base and `rev`: those the pull request's commits changed.
    Results are the bot's; its results commit puts these back as they are at the merge base."""
    return [f for f in git(repo, "diff", "--name-only", base, rev).splitlines() if RESULTS_PATH.match(f)]


def missing_files(repo, tip, system):
    """The files a system needs (SYSTEM_FILES) that it does not have, or not with the right mode."""
    have = {line.split("\t", 1)[1].rsplit("/", 1)[1]: line.split()[0]
            for line in git(repo, "ls-tree", tip, "--", f"systems/{system}/").splitlines()}
    return [f"`{f}`" + (" (not executable)" if f in have else "") for f, mode in SYSTEM_FILES.items() if have.get(f) != mode]


# ---------------------------------------------------------------------------------------------------------------
# The results of a run, as the reply's table

def summary(text):
    """A results CSV (systems/<system>/results/<date>/<config>.csv) in a few numbers: the loads' time, the last
    run's queries by status, their time and geometric mean, what failed."""
    rows = list(csv.DictReader(io.StringIO(text)))
    s = {"loads": sum(float(r["median_s"]) for r in rows if r["query"] == "load" and r["median_s"]),
         "failed": [r for r in rows if r["status"].startswith("failed_") or r["status"] == "not_supported"],
         "ok": 0, "wrong_result": 0, "error": 0, "timeout": 0, "time": 0.0, "geomean": None, "queries": []}
    queries = [r for r in rows if r["query"] not in ("load", "")]
    if queries:
        last = max(int(r["run"]) for r in queries)
        s["queries"] = [r for r in queries if int(r["run"]) == last]
        for r in s["queries"]:
            s[r["status"]] = s.get(r["status"], 0) + 1
        ok = [float(r["median_s"]) for r in s["queries"] if r["status"] == "ok" and r["median_s"]]
        s["time"] = sum(ok)
        s["geomean"] = math.exp(sum(math.log(max(t, 1e-6)) for t in ok) / len(ok)) if ok else None
    return s


def fmt_s(t):
    return "–" if t is None else f"{t * 1000:.3g} ms" if t < 1 else f"{t:.3g} s" if t < 1000 else f"{t:.0f} s"


def table(results):
    """`results`: [(system, config, summary, summary on main or None)] as a Markdown table."""
    out = ["| System | Config | Loads | OK | Wrong | Error | Timeout | Time (OK) | Geomean (OK) | On main: OK, time |",
           "|---|---|--:|--:|--:|--:|--:|--:|--:|--:|"]
    for system, config, s, m in results:
        failed = f" ({', '.join(sorted({r['status'] for r in s['failed']}))})" if s["failed"] else ""
        out.append(f"| {system} | {config}{failed} | {fmt_s(s['loads'])} | {s['ok']} | {s['wrong_result']} | {s['error']} | "
                   f"{s['timeout']} | {fmt_s(s['time'])} | {fmt_s(s['geomean'])} | "
                   + (f"{m['ok']}, {fmt_s(m['time'])}" if m else "–") + " |")
    return "\n".join(out)
