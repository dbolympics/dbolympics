#!/usr/bin/env python3
"""The benchmark bot: when a maintainer of the repository comments `/benchmark` on a pull request, it runs the pull
request's systems on this machine, adds their results to the pull request as its last commit, and replies with a
table of them. It polls GitHub, so that the machine needs no open port. See docs/BOT.md.

    python3 tools/bot/bot.py [--config ~/.config/dbo-bot/config.toml]

The commands, each at the start of a line of a comment:
    /benchmark [system ...] [sfN | sfN-<config> ...] [@<commit>]
                        run the systems (default: those the pull request changes) on the benchmark files
                        (bench/benchmark_sfN.toml; default: the configuration's `benchmarks`) or single
                        configurations of them, on the pull request's commit (or only if that is <commit>)
    /benchmark move     move the results commit to the end again, without running anything
    /benchmark cancel   stop the pull request's run, or take it out of the queue
    /benchmark status   what runs and what waits
"""
import argparse
import base64
import datetime
import getpass
import json
import os
import re
import signal
import subprocess
import sys
import threading
import time
import tomllib
import traceback
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from common import (APPROVED_TRAILER, ORGANIZATION_FORK, RESULTS_PATH, RESULTS_TRAILER, SYSTEM_NAME, SYSTEM_TRAILER, benchmarked,  # noqa: E402
                    changed_systems, code_hash, git, problems, run_tree, split, summary, table, trailers, user_results)

DEFAULTS = {
    "repo": "dbolympics/dbolympics",
    # the GitHub App the bot is (docs/BOT.md): it comments, reacts and pushes as the app's bot account
    "app_id": None,
    "installation_id": None,
    "key_file": "~/.ssh/db-olympics-bot.pem",  # the app's private key
    "work": "~/dbo-bot",                     # the clone, the runs' checkout with its data, the logs, the state
    "poll_seconds": 30,
    "reserve_hours": 24,                     # each system's time on the machine at most: then it is released and the run killed
    "benchmarks": ["sf1", "sf10", "sf100", "sf1000"],  # a plain /benchmark
}
COMMAND = re.compile(r"^/benchmark\b[ \t]*(.*)$", re.M)
MAINTAINERS = {"admin", "maintain"}          # the roles that may start a run
MAX_COMMENT = 60000                          # GitHub's limit is 65536 characters


def log(msg):
    print(f"{datetime.datetime.now():%Y-%m-%d %H:%M:%S} {msg}", flush=True)


class Refused(Exception):
    """The run cannot go ahead, for a reason the reply gives."""


class Cancelled(Exception):
    pass


class GitHub:
    """The REST API as the app's installation: a token for an hour at a time, from a JWT signed with the app's key."""

    def __init__(self, repo, app_id, installation_id, key_file):
        self.repo, self.app_id, self.installation_id, self.key_file = repo, str(app_id), installation_id, key_file
        self._token, self._expires, self._lock = None, 0, threading.Lock()

    def jwt(self):
        b64 = lambda b: base64.urlsafe_b64encode(b).rstrip(b"=")
        now = int(time.time())
        msg = b64(b'{"alg":"RS256","typ":"JWT"}') + b"." + b64(json.dumps({"iat": now - 60, "exp": now + 540, "iss": self.app_id}).encode())
        sig = subprocess.run(["openssl", "dgst", "-sha256", "-sign", self.key_file], input=msg, capture_output=True, check=True).stdout
        return (msg + b"." + b64(sig)).decode()

    @property
    def token(self):
        with self._lock:
            if time.time() > self._expires - 600:
                req = urllib.request.Request(f"https://api.github.com/app/installations/{self.installation_id}/access_tokens",
                                             method="POST", headers={"Authorization": f"Bearer {self.jwt()}", "User-Agent": "dbo-bot",
                                                                     "Accept": "application/vnd.github+json"})
                with urllib.request.urlopen(req, timeout=60) as r:
                    t = json.load(r)
                self._token = t["token"]
                self._expires = datetime.datetime.fromisoformat(t["expires_at"].replace("Z", "+00:00")).timestamp()
            return self._token

    def app(self):
        """The app's bot account: (login, the commits' e-mail address)."""
        req = urllib.request.Request("https://api.github.com/app", headers={"Authorization": f"Bearer {self.jwt()}", "User-Agent": "dbo-bot",
                                                                            "Accept": "application/vnd.github+json"})
        with urllib.request.urlopen(req, timeout=60) as r:
            slug = json.load(r)["slug"]
        user = self.get(f"/users/{slug}%5Bbot%5D")
        return user["login"], f"{user['id']}+{user['login']}@users.noreply.github.com"

    def call(self, method, path, body=None):
        url = path if path.startswith("https://") else f"https://api.github.com{path}"
        for attempt in range(6):
            req = urllib.request.Request(url, method=method, data=None if body is None else json.dumps(body).encode(),
                                         headers={"Authorization": f"Bearer {self.token}", "Accept": "application/vnd.github+json",
                                                  "X-GitHub-Api-Version": "2022-11-28", "User-Agent": "dbo-bot"})
            try:
                with urllib.request.urlopen(req, timeout=60) as r:
                    data = r.read()
                    return json.loads(data) if data else None, r.headers
            except urllib.error.HTTPError as e:
                if e.code < 500 and e.code not in (403, 429):  # 403 and 429: rate limits; 5xx: GitHub's trouble
                    raise
            except (urllib.error.URLError, TimeoutError):
                pass
            time.sleep(min(300, 10 * 2 ** attempt))
        raise RuntimeError(f"GitHub: {method} {url} failed")

    def get(self, path):
        return self.call("GET", path)[0]

    def get_all(self, path):
        out, url = [], path
        while url:
            data, headers = self.call("GET", url)
            out += data
            url = next((m.group(1) for m in re.finditer(r'<([^>]+)>;\s*rel="next"', headers.get("Link") or "")), None)
        return out

    def comment(self, pr, body):
        return self.call("POST", f"/repos/{self.repo}/issues/{pr}/comments", {"body": body[:MAX_COMMENT]})[0]

    def edit(self, comment_id, body):
        self.call("PATCH", f"/repos/{self.repo}/issues/comments/{comment_id}", {"body": body[:MAX_COMMENT]})

    def react(self, comment_id, content):
        try:
            self.call("POST", f"/repos/{self.repo}/issues/comments/{comment_id}/reactions", {"content": content})
        except urllib.error.HTTPError as e:
            log(f"reaction {content} on {comment_id}: {e}")

    def role(self, login):
        """The user's role in the repository (admin, maintain, write, triage, read), or None."""
        try:
            return self.get(f"/repos/{self.repo}/collaborators/{login}/permission").get("role_name")
        except urllib.error.HTTPError as e:
            if e.code == 404:
                return None
            raise


class Bot:
    def __init__(self, cfg):
        self.cfg = cfg
        self.work = Path(os.path.expanduser(cfg["work"]))
        self.mirror, self.run_dir, self.logs = self.work / "git", self.work / "run", self.work / "logs"
        self.state_file = self.work / "state.json"
        self.gh = GitHub(cfg["repo"], cfg["app_id"], cfg["installation_id"], os.path.expanduser(cfg["key_file"]))
        self.git_lock, self.state_lock = threading.Lock(), threading.Lock()
        self.proc, self.cancel = None, threading.Event()
        self.state = json.loads(self.state_file.read_text()) if self.state_file.exists() else {
            "last_id": 0, "since": datetime.datetime.now(datetime.UTC).strftime("%Y-%m-%dT%H:%M:%SZ"),
            "queue": [], "current": None, "told": []}

    def save(self):
        tmp = self.state_file.with_suffix(".tmp")
        tmp.write_text(json.dumps(self.state, indent=1))
        os.replace(tmp, self.state_file)

    # ---------------------------------------------------------------------------------------------------------
    # The clone: a bare clone of the repository, its pull requests fetched into refs/pr/<n>, and the runs' checkout
    # (with the generated data and the build, which stay from run to run) a worktree of it

    def setup(self):
        self.logs.mkdir(parents=True, exist_ok=True)
        if not self.mirror.exists():
            subprocess.run(["git", "init", "--quiet", "--bare", str(self.mirror)], check=True)
            git(self.mirror, "remote", "add", "origin", f"https://github.com/{self.cfg['repo']}.git")
        git(self.mirror, "fetch", "--quiet", "origin", "+refs/heads/main:refs/heads/main")
        git(self.mirror, "worktree", "prune")
        if not self.run_dir.exists():
            git(self.mirror, "worktree", "add", "--quiet", "--detach", str(self.run_dir), "main")

    def fetch(self, pr):
        git(self.mirror, "fetch", "--quiet", "--force", "origin", "+refs/heads/main:refs/heads/main", f"+refs/pull/{pr}/head:refs/pr/{pr}")
        return git(self.mirror, "rev-parse", f"refs/pr/{pr}")

    def identity(self):
        n, e = self.login, self.email
        return dict(os.environ, GIT_AUTHOR_NAME=n, GIT_AUTHOR_EMAIL=e, GIT_COMMITTER_NAME=n, GIT_COMMITTER_EMAIL=e)

    def pr_tip(self, pr):
        """The pull request as it is: (its head, the merge base, its results commits, its last commit without
        them, whether that is a new one). Results commits before the end are dropped by rewriting the commits
        after them (drop), which makes those new commits."""
        head = self.fetch(pr)
        base, results, tip = split(self.mirror, "main", head)
        rebased = bool(results) and git(self.mirror, "rev-list", f"{tip}..{head}").split() != list(reversed(results))
        if rebased:
            tip = head
            for r in reversed(results):  # the newest first: dropping it leaves the older ones as they are
                tip = self.drop(r, tip)
            changed = git(self.mirror, "diff", "--name-only", head, tip).splitlines()
            assert all(RESULTS_PATH.match(f) for f in changed), f"dropping the results commits changed {changed}"
        return head, base, results, tip, rebased

    def drop(self, results_commit, head):
        """`head` without the results commit: the commits after it again, on its parent instead (committed by the
        bot, their authors, dates and messages kept). They keep their files, except those the results commit
        changed and they did not change again: those are as before the results commit. Unlike a rebase, this has no
        conflicts."""
        parent = git(self.mirror, "rev-parse", f"{results_commit}^")
        entry = lambda rev, path: tuple(git(self.mirror, "ls-tree", rev, "--", path).split()[:3]) or None
        touched = {path: (entry(results_commit, path), entry(parent, path)) for _, _, path in self.changes_of(results_commit)}
        new = {results_commit: parent}
        index = self.work / "index"
        for c in git(self.mirror, "rev-list", "--reverse", "--topo-order", "--ancestry-path", f"{results_commit}..{head}").split():
            env = dict(os.environ, GIT_INDEX_FILE=str(index))
            index.unlink(missing_ok=True)
            git(self.mirror, "read-tree", c, env=env)
            # as the results commit left them: as before it
            update_index(self.mirror, env, [(before[0], before[2], path) if before else (None, None, path)
                                            for path, (theirs, before) in touched.items() if entry(c, path) == theirs])
            tree = git(self.mirror, "write-tree", env=env)
            index.unlink()
            name, email, date = git(self.mirror, "log", "-1", "--format=%an%x00%ae%x00%ad", "--date=raw", c).split("\0")
            parents = [a for p in git(self.mirror, "rev-list", "--parents", "-n1", c).split()[1:] for a in ("-p", new.get(p, p))]
            new[c] = git(self.mirror, "commit-tree", *parents, "-F", "-", tree, input=git(self.mirror, "log", "-1", "--format=%B", c),
                         env=dict(self.identity(), GIT_AUTHOR_NAME=name, GIT_AUTHOR_EMAIL=email, GIT_AUTHOR_DATE=date))
        return new[head]

    def run_commit(self, pr, base, tip):
        """A commit on main of the tree a run of the pull request has (run_tree); not pushed anywhere."""
        index = self.work / "index"
        env = dict(self.identity(), GIT_INDEX_FILE=str(index))
        index.unlink(missing_ok=True)
        tree = run_tree(self.mirror, "main", base, tip, env)
        index.unlink()
        return git(self.mirror, "commit-tree", "-p", "main", "-F", "-", tree, env=env,
                   input=f"The systems of pull request #{pr} at {tip[:10]} on main, as the bot runs them\n")

    def write_commit(self, parent, changes, message):
        """A commit on `parent` with `changes` [(mode, blob, path)] (blob None: removed)."""
        index = self.work / "index"
        env = dict(self.identity(), GIT_INDEX_FILE=str(index))
        index.unlink(missing_ok=True)
        git(self.mirror, "read-tree", parent, env=env)
        update_index(self.mirror, env, changes)
        tree = git(self.mirror, "write-tree", env=env)
        index.unlink()
        return git(self.mirror, "commit-tree", "-p", parent, "-F", "-", tree,
                   env=env, input=message)

    def undo_user_results(self, base, tip, changes):
        """The changes [(mode, blob, path)] that put the results files the pull request changed (user_results) back
        as they are at the merge base, apart from those in `changes`: results are the bot's."""
        ours, out = {p for _, _, p in changes}, []
        for path in user_results(self.mirror, base, tip):
            if path not in ours:
                entry = git(self.mirror, "ls-tree", base, "--", path).split()
                out.append((entry[0], entry[2], path) if entry else ("100644", None, path))
        return out

    def changes_of(self, commit, systems=None):
        """A commit's changes against its parent, [(mode, blob, path)], only of `systems` if given."""
        out = []
        for line in git(self.mirror, "diff-tree", "-r", "--no-commit-id", commit).splitlines():
            meta, path = line.split("\t", 1)
            _, mode, _, blob, status = meta.split()
            if systems is None or path.split("/")[1] in systems:
                out.append((mode, None if status == "D" else blob, path))
        return out

    def push(self, pr_json, expected, commit):
        """Push `commit` as the pull request's branch, if that is still at `expected`. False if it is not."""
        head = pr_json["head"]
        auth = base64.b64encode(f"x-access-token:{self.gh.token}".encode()).decode()
        env = dict(os.environ, GIT_TERMINAL_PROMPT="0", GIT_CONFIG_COUNT="1",
                   GIT_CONFIG_KEY_0="http.https://github.com/.extraheader", GIT_CONFIG_VALUE_0=f"AUTHORIZATION: basic {auth}")
        r = subprocess.run(["git", "-C", str(self.mirror), "push", "--quiet", f"--force-with-lease=refs/heads/{head['ref']}:{expected}",
                            f"https://github.com/{head['repo']['full_name']}.git", f"{commit}:refs/heads/{head['ref']}"],
                           env=env, capture_output=True, text=True)
        if r.returncode:
            if "stale info" in r.stderr or "rejected" in r.stderr:
                return False
            raise RuntimeError(f"git push: {r.stderr.strip()}")
        return True

    # ---------------------------------------------------------------------------------------------------------
    # Comments

    def poll(self):
        comments = self.gh.get_all(f"/repos/{self.cfg['repo']}/issues/comments?since={urllib.parse.quote(self.state['since'])}"
                                   "&sort=created&direction=asc&per_page=100")
        for c in sorted(comments, key=lambda c: c["id"]):
            if c["id"] <= self.state["last_id"]:
                continue  # seen, or edited since: an edit is no new command
            with self.state_lock:
                self.state["last_id"], self.state["since"] = c["id"], c["created_at"]
                self.save()
            m = COMMAND.search(c["body"] or "")
            if not m or c["user"]["login"] == self.login:
                continue
            try:
                self.handle(c, int(c["issue_url"].rsplit("/", 1)[1]), m.group(1).split())
            except Exception:
                log(f"comment {c['html_url']}:\n{traceback.format_exc()}")
                self.gh.comment(int(c["issue_url"].rsplit("/", 1)[1]), quote(c) + "The bot failed on this command; "
                                "the maintainers find why in its log.")

    def handle(self, c, n, words):
        try:
            pr = self.gh.get(f"/repos/{self.cfg['repo']}/pulls/{n}")
        except urllib.error.HTTPError as e:
            if e.code == 404:
                return  # an issue, not a pull request
            raise
        who = c["user"]["login"]
        role = self.gh.role(who)
        if role not in MAINTAINERS:
            log(f"#{n}: {who} ({role}) is no maintainer")
            if n not in self.state["told"]:
                self.gh.react(c["id"], "-1")
                self.gh.comment(n, quote(c) + "Only the maintainers of the repository can start a benchmark.")
                with self.state_lock:
                    self.state["told"].append(n)
                    self.save()
            return
        log(f"#{n}: {who} ({role}): /benchmark {' '.join(words)}")
        self.gh.react(c["id"], "eyes")
        cmd = words[0] if words else ""
        if cmd == "status":
            self.gh.comment(n, quote(c) + self.status())
        elif cmd == "cancel":
            self.cancel_pr(c, n, who)
        elif cmd == "move":
            self.move(c, n, pr, who)
        else:
            self.request(c, n, pr, who, role, words)

    def status(self):
        with self.state_lock:
            cur, queue = self.state["current"], list(self.state["queue"])
        st = sh(["reserve-machine", "status"]).splitlines()
        lines = [f"**Machine:** {', '.join(st) or 'unknown'}",
                 f"**Running:** #{cur['pr']}, {describe(cur)}, since {cur.get('started', '?')}" if cur else "**Running:** nothing"]
        lines += [f"**Waiting:**"] + [f"{k + 1}. #{j['pr']}, {describe(j)}" for k, j in enumerate(queue)] if queue else ["**Waiting:** nothing"]
        return "\n".join(lines)

    def cancel_pr(self, c, n, who):
        with self.state_lock:
            queued = [j for j in self.state["queue"] if j["pr"] == n]
            self.state["queue"] = [j for j in self.state["queue"] if j["pr"] != n]
            self.save()
            running = self.state["current"] and self.state["current"]["pr"] == n
        for j in queued:
            self.gh.edit(j["reply_id"], j["intro"] + f"Cancelled by @{who} before it ran.")
        if running:
            self.state["current"]["cancelled_by"] = who
            self.cancel.set()
            self.stop_proc()
        self.gh.react(c["id"], "+1" if queued or running else "confused")
        if not queued and not running:
            self.gh.comment(n, quote(c) + "Nothing runs or waits for this pull request.")

    def request(self, c, n, pr, who, role, words):
        pin = next((w[1:] for w in words if w.startswith("@")), None)
        sfs = [w for w in words if re.fullmatch(r"sf\d+(-\S+)?", w)]
        named = [w for w in words if w not in sfs and not w.startswith("@")]
        intro = quote(c)
        reply = self.gh.comment(n, intro + "Checking the pull request ...")
        try:
            if pr["state"] != "open" or pr["base"]["ref"] != "main":
                raise Refused("The bot runs open pull requests into main only.")
            if not pr["head"]["repo"]:
                raise Refused("The pull request's repository is gone.")
            if pr["head"]["repo"]["full_name"] != self.cfg["repo"] and pr["head"]["repo"]["owner"]["type"] == "Organization":
                raise Refused(ORGANIZATION_FORK)
            if pr["head"]["repo"]["full_name"] != self.cfg["repo"] and not pr["maintainer_can_modify"]:
                raise Refused("The bot adds the results to the pull request's branch: allow edits by maintainers "
                              "(the checkbox on the pull request), then ask again.")
            with self.git_lock:
                sha, base, _, tip, _ = self.pr_tip(n)
                if pin and not (sha.startswith(pin) or tip.startswith(pin)):
                    raise Refused(f"The pull request is at `{sha[:10]}`, not `{pin}`.")
                if errs := [p for _, p in problems(self.mirror, "main", base, tip)]:
                    raise Refused("The bot does not run this pull request:\n" + "\n".join(f"- {e}" for e in errs))
                changed, _ = changed_systems(self.mirror, base, tip)
                # the systems of the run (run_tree): main's, and the pull request's own, without those it removes
                has = lambda rev, s: bool(git(self.mirror, "ls-tree", rev, "--", f"systems/{s}/system.toml"))
                on_main = {path.split("/")[1] for path in git(self.mirror, "ls-tree", "-r", "--name-only", "main", "--", "systems/").splitlines()
                           if path.count("/") == 2 and path.endswith("/system.toml")}
                available = sorted((on_main - set(changed)) | {s for s in changed if has(tip, s)})
                # `all`: every system of the run
                systems = available if "all" in named else named or changed
                if not systems:
                    raise Refused("The pull request changes no system: name the systems, e.g. `/benchmark duckdb`, "
                                  "or run them all with `/benchmark all`.")
                for s in systems:
                    if not SYSTEM_NAME.match(s) or s not in available:
                        raise Refused(f"There is no system `{s}` in the pull request.")
                benchmarks = self.benchmarks(sfs or self.cfg["benchmarks"])
                tree = git(self.mirror, "rev-parse", f"{tip}^{{tree}}")
        except Refused as e:
            self.gh.edit(reply["id"], intro + str(e))
            self.gh.react(c["id"], "confused")
            return
        job = {"id": f"{n}-{c['id']}", "pr": n, "comment_id": c["id"], "comment_url": c["html_url"], "approver": who,
               "role": role, "systems": systems, "benchmarks": benchmarks, "tree": tree, "commit": tip,
               "reply_id": reply["id"], "intro": intro}
        with self.state_lock:
            self.state["queue"].append(job)
            self.save()
            ahead = len(self.state["queue"]) - 1 + (self.state["current"] is not None)
        self.gh.edit(reply["id"], intro + f"Queued: {describe(job)} on commit `{tip[:10]}`"
                     + (f", after {ahead} other {'run' if ahead == 1 else 'runs'}." if ahead else "."))

    def benchmarks(self, words):
        """`sfN` and `sfN-<config>` as [(benchmark file, [configs] or [] for all)], from main."""
        out = {}
        for w in words:
            sf = w.split("-", 1)[0]
            path = f"bench/benchmark_{sf}.toml"
            try:
                names = [c["name"] for c in tomllib.loads(git(self.mirror, "show", f"main:{path}"))["config"]]
            except subprocess.CalledProcessError:
                raise Refused(f"There is no `{path}`.")
            if w == sf:
                out[path] = None  # all of them
            elif w not in names:
                raise Refused(f"`{path}` has no configuration `{w}` ({', '.join(names)}).")
            elif out.get(path, []) is not None:
                out.setdefault(path, []).append(w)
        return [(p, cs or []) for p, cs in out.items()]

    def move(self, c, n, pr, who):
        with self.git_lock:
            head, base, results, tip, _ = self.pr_tip(n)
            if not results:
                self.gh.comment(n, quote(c) + "The pull request has no results commit.")
                return
            if results == [head]:
                self.gh.comment(n, quote(c) + "The results commit is the last commit already.")
                return
            old = results[-1]
            changes = self.changes_of(old)
            commit = self.write_commit(tip, changes + self.undo_user_results(base, tip, changes),
                                       git(self.mirror, "log", "-1", "--format=%B", old))
            if not self.push(pr, head, commit):
                self.gh.comment(n, quote(c) + "The pull request changed meanwhile; ask again.")
                return
        old_code = [s for s, h in benchmarked(self.mirror, old).items() if code_hash(self.mirror, tip, s) != h]
        self.gh.react(c["id"], "rocket")
        self.gh.comment(n, quote(c) + f"Moved the results commit to the end: `{commit[:10]}`. " + REBASED + "\n\n"
                        + (f"The results of {', '.join(old_code)} are of older code: the system changed after the run, "
                           "so run the benchmark again." if old_code else "The results are still of the systems' code as it is."))

    # ---------------------------------------------------------------------------------------------------------
    # Runs

    def worker(self):
        while True:
            if not self.work_one():
                time.sleep(5)

    def work_one(self):
        """Run the first job of the queue and reply with how it went; False if there is none."""
        with self.state_lock:
            job = self.state["queue"].pop(0) if self.state["queue"] else None
            if job:
                job["started"] = datetime.datetime.now().strftime("%Y-%m-%d %H:%M")
                self.state["current"] = job
                self.save()
        if not job:
            return False
        self.cancel.clear()
        try:
            body, ok = self.run(job)
        except Cancelled:
            body, ok = f"Cancelled by @{job.get('cancelled_by', '?')}.", False
        except Refused as e:
            body, ok = str(e), False
        except Exception:
            log(f"run {job['id']}:\n{traceback.format_exc()}")
            body, ok = "The run failed.\n\n" + details("The end of the log", self.tail(job)), False
        finally:
            self.cleanup()
            try:
                self.release(job)
            except Exception:  # the timed release (with --kill) still comes
                log(f"run {job['id']}: releasing the machine failed:\n{traceback.format_exc()}")
        try:
            self.gh.edit(job["reply_id"], job["intro"] + body)
            self.gh.react(job["comment_id"], "rocket" if ok else "confused")
        except Exception:
            log(f"run {job['id']}: the reply failed:\n{traceback.format_exc()}\n{body}")
        with self.state_lock:
            self.state["current"] = None
            self.save()
        return True

    def stage(self, job, text):
        log(f"run {job['id']}: {text}")
        try:  # a reply GitHub does not take now is no reason to stop the run
            self.gh.edit(job["reply_id"], job["intro"] + f"{text}\n\n{describe(job)} on commit `{job['commit'][:10]}`, "
                         f"started {job['started']}.")
        except Exception:
            log(f"run {job['id']}: the reply failed:\n{traceback.format_exc()}")

    def run(self, job):
        n = job["pr"]
        with self.git_lock:
            head, base, results, tip, rebased = self.pr_tip(n)
            if git(self.mirror, "rev-parse", f"{tip}^{{tree}}") != job["tree"]:
                raise Refused("The pull request has new commits since the approval: approve again with `/benchmark`.")
            if errs := [p for _, p in problems(self.mirror, "main", base, tip)]:
                raise Refused("The bot does not run this pull request:\n" + "\n".join(f"- {e}" for e in errs))
            pr = self.gh.get(f"/repos/{self.cfg['repo']}/pulls/{n}")
            job["commit"] = tip
            # the pull request's systems on main (run_tree): main's runner, whatever main the branch started from
            git(self.run_dir, "checkout", "--quiet", "--detach", "--force", self.run_commit(n, base, tip))
            git(self.run_dir, "clean", "-ffdq")  # untracked files go, the ignored ones (data/, target/) stay

        self.stage(job, "Building the runner ...")
        if self.sh_logged(job, ["cargo", "build", "--release", "--workspace", "--locked"]):
            raise Refused("Building the runner failed.\n\n" + details("The end of the log", self.tail(job)))
        self.reserve(job)
        failed = []
        # one system after the other, each with all its configurations and `reserve_hours` of its own
        for k, system in enumerate(job["systems"]):
            if k:
                self.schedule_release(job)
            job["system"] = system
            failed_now = []
            for bench, configs in job["benchmarks"]:
                self.stage(job, f"Running {system} on `{bench}`, system {k + 1} of {len(job['systems'])} "
                                f"(stopped at the latest {job['deadline']}) ...")
                cmd = ["target/release/dbo-bench", "run", "--benchmark", bench, "--system", system] + [a for c in configs for a in ("--config", c)]
                if self.sh_logged(job, cmd):
                    failed_now.append(bench)
            failed += [f"{system} on {b}" for b in failed_now]
            self.system_done(job, system, k, failed_now)
        self.cleanup()
        self.release(job)

        files = self.result_files(job["systems"])
        if not files:
            raise Refused("The run wrote no results.\n\n" + details("The end of the log", self.tail(job)))

        with self.git_lock:
            # the earlier results of the systems whose code is still the same stay: of the systems not run now, and of
            # the configurations not run now of those that ran (e.g. after `/benchmark clickhouse sf1000`)
            old = results[-1] if results else None
            before = benchmarked(self.mirror, old) if old else {}
            same = sorted(s for s, h in before.items() if code_hash(self.mirror, tip, s) == h)
            kept = [s for s in same if s not in job["systems"]]
            config = lambda path: (path.split("/")[1], path.rsplit("/", 1)[1].rsplit(".", 1)[0])  # (system, configuration)
            now = {config(p) for p in files}
            earlier = [c for c in (self.changes_of(old, same) if old else []) if config(c[2]) not in now]
            partly = sorted({config(p)[0] for _, _, p in earlier} & set(job["systems"]))
            changes = [("100644", git(self.run_dir, "hash-object", "-w", p), p) for p in files] + earlier
            code = {**{s: before[s] for s in kept}, **{s: code_hash(self.mirror, tip, s) for s in job["systems"]}}
            message = (f"Benchmark results of {', '.join(code)}\n\nRun by the benchmark bot for pull request #{n}, "
                       f"approved by @{job['approver']}: {job['comment_url']}\n\n{RESULTS_TRAILER}: {' '.join(code)}\n"
                       + "".join(f"{SYSTEM_TRAILER}: {s} {h}\n" for s, h in code.items())
                       + f"{APPROVED_TRAILER}: {job['approver']}\n")
            undone = self.undo_user_results(base, tip, changes)
            commit = self.write_commit(tip, changes + undone, message)
            pushed = self.push(pr, head, commit)

        # each system's table is in a comment of its own (system_done)
        links = job.get("system_comments", {})
        out = [f"**{describe(job)}** on commit `{tip[:10]}`" + (f": the runner reported failures in {', '.join(failed)}." if failed else "."), "",
               "The results of each system: " + ", ".join(f"[{s}]({links[s]})" if links.get(s) else s for s in job["systems"]) + ".", ""]
        if kept:
            out.append(f"The results of {', '.join(kept)} from the earlier run stay in the commit.")
        if partly:
            out.append(f"The earlier results of {', '.join(partly)} in the configurations not run now stay in the commit.")
        if undone:
            out.append("The commit undoes the pull request's own changes to results ("
                       + ", ".join(f"`{p}`" for _, _, p in undone[:10]) + (" ..." if len(undone) > 10 else "") + ").")
        if pushed:
            out.append(f"The results are the pull request's last commit, `{commit[:10]}`." + (" " + REBASED if rebased else ""))
        else:
            out.append("**Not added to the pull request:** it has new commits since the run started. "
                       "Run the benchmark again with `/benchmark`.")
        return "\n".join(out), pushed and not failed

    def result_files(self, systems):
        """The results the run wrote of `systems`: new or changed files in their results directories."""
        # not stripped: the status's first column may be a space
        status = subprocess.run(["git", "-C", str(self.run_dir), "status", "--porcelain", "-z", "--untracked-files=all", "--", "systems"],
                                capture_output=True, text=True, check=True).stdout
        return sorted(line[3:] for line in filter(None, status.split("\0"))
                      if RESULTS_PATH.match(line[3:]) and line[3:].split("/")[1] in systems and line[:2] in ("??", " M"))

    def result_rows(self, files):
        """The table's rows of the results files: (system, configuration, summary, summary on main)."""
        return [(p.split("/")[1], p.rsplit("/", 1)[1][:-4], summary((self.run_dir / p).read_text()), self.on_main(p.split("/")[1], p.rsplit("/", 1)[1][:-4]))
                for p in files if p.endswith(".csv")]

    def system_done(self, job, system, k, failed):
        """A comment of its own on the pull request with the table of a system that has run all its configurations."""
        rows = self.result_rows(self.result_files([system]))
        body = (f"**{system}** is done, system {k + 1} of {len(job['systems'])} of [the run]({job['comment_url']}) on commit "
                f"`{job['commit'][:10]}`" + (f": the runner reported failures in {', '.join(failed)}." if failed else ".") + "\n\n"
                + (table(rows) + "\n\n" + not_ok(rows) if rows else "It wrote no results.\n\n" + details("The end of the log", self.tail(job))))
        try:  # a comment GitHub does not take now is no reason to stop the run
            job.setdefault("system_comments", {})[system] = self.gh.comment(job["pr"], body).get("html_url")
            with self.state_lock:
                self.save()
        except Exception:
            log(f"run {job['id']}: the comment on {system} failed:\n{traceback.format_exc()}")

    def on_main(self, system, config):
        """The summary of the system's newest results for the configuration on main, if there are any."""
        paths = [p for p in git(self.mirror, "ls-tree", "-r", "--name-only", "main", "--", f"systems/{system}/results/").splitlines()
                 if p.endswith(f"/{config}.csv")]
        return summary(git(self.mirror, "show", f"main:{max(paths)}")) if paths else None

    def reserve(self, job):
        """Wait until nobody holds the machine, then reserve it, released after `reserve_hours` at the latest
        (schedule_release)."""
        said = None
        while not (st := sh(["reserve-machine", "status"]).strip()).startswith("not reserved"):
            if self.cancel.is_set():
                raise Cancelled
            if st != said:
                self.stage(job, f"Waiting for the machine: {st.splitlines()[0]}.")
                said = st
            self.cancel.wait(60)
        sh(["reserve-machine", f"{self.cfg['reserve_hours']}h", "-y"], check=True)
        job["reserved_at"] = time.time()
        self.schedule_release(job)

    def schedule_release(self, job):
        """Release the machine `reserve_hours` from now, and kill everything of this user then (the run, its
        containers, this bot, which systemd restarts); a release scheduled before is replaced."""
        hours = self.cfg["reserve_hours"]
        job["release_at"] = time.time() + hours * 3600
        job["deadline"] = (datetime.datetime.now() + datetime.timedelta(hours=hours)).strftime("%Y-%m-%d %H:%M")
        with self.state_lock:
            self.save()
        sh(["release-machine", f"{hours}h", "--kill", "-y"], check=True)

    def release(self, job):
        if job.pop("reserved_at", None):
            sh(["release-machine", "-y"], check=True)
            with self.state_lock:
                self.save()

    def cleanup(self):
        """Nothing of a run is left: the runner's containers' storage (bench/containers) is reset, its pods, containers,
        volumes and images with the databases' files go (the next run builds the images again)."""
        storage = self.run_dir / "bench" / "containers" / "storage"
        if not storage.is_dir():
            return
        podman = ["podman", "--root", str(storage), "--runroot", f"/run/user/{os.getuid()}/dbo-containers"]
        r = subprocess.run(podman + ["system", "reset", "--force"], capture_output=True, text=True)
        left = [f"{d}/{p.name}" for d in ("overlay", "volumes") if (storage / d).is_dir() for p in (storage / d).iterdir()
                if p.name != "l" and not p.name.startswith(".")]  # overlay/l and podman's marker files stay
        if r.returncode or left:
            log(f"resetting the containers' storage {storage}: {(r.stdout + r.stderr).strip()[-2000:]}; left: {', '.join(left[:20]) or 'nothing'}")

    def sh_logged(self, job, cmd):
        """Run `cmd` in the checkout, its output into the run's log; its exit status. A cancel stops it."""
        with open(self.logs / f"{job['id']}.log", "a") as f:
            f.write(f"\n$ {' '.join(cmd)}\n")
            f.flush()
            self.proc = subprocess.Popen(cmd, cwd=self.run_dir, stdout=f, stderr=subprocess.STDOUT, start_new_session=True)
            code = self.proc.wait()
            self.proc = None
        if self.cancel.is_set():
            raise Cancelled
        return code

    def stop_proc(self):
        p = self.proc
        if p:
            for sig, wait in ((signal.SIGTERM, 60), (signal.SIGKILL, 10)):
                try:
                    os.killpg(p.pid, sig)
                    p.wait(wait)
                    return
                except (ProcessLookupError, subprocess.TimeoutExpired):
                    pass

    def tail(self, job, lines=40):
        path = self.logs / f"{job['id']}.log"
        return "\n".join(path.read_text(errors="replace").splitlines()[-lines:])[-8000:] if path.exists() else ""

    def recover(self):
        """A run the bot did not finish: its containers go, the machine is released if it is still reserved, and the
        reply says why (the time limit, or a restart of the bot)."""
        job = self.state["current"]
        if not job:
            return
        self.cleanup()
        reason = "the bot was restarted during the run"
        if job.get("reserved_at"):
            if sh(["reserve-machine", "status"]).startswith(f"reserved by {getpass.getuser()}"):
                sh(["release-machine", "-y"])
            elif time.time() >= job.get("release_at", 0) - 300:
                reason = f"{job.get('system', 'the run')} did not finish within {self.cfg['reserve_hours']} hours and was stopped"
        log(f"run {job['id']}: {reason}")
        self.gh.edit(job["reply_id"], job["intro"] + f"Failed: {reason}.\n\n" + details("The end of the log", self.tail(job)))
        self.gh.react(job["comment_id"], "confused")
        self.state["current"] = None
        self.save()

    def main(self):
        # no limit on locked memory for the runner (io_uring, Umbra), as bench/host-setup.sh says
        sh(["sudo", "-n", "prlimit", "--pid", str(os.getpid()), "--memlock=unlimited:unlimited"])
        self.login, self.email = self.gh.app()
        log(f"the GitHub App's account: {self.login} <{self.email}>")
        self.setup()
        if not self.state_file.exists():
            self.save()  # from now on: comments made while the bot is down are read when it is back
        self.recover()
        threading.Thread(target=self.worker, daemon=True).start()
        log(f"polling {self.cfg['repo']} every {self.cfg['poll_seconds']} s")
        while True:
            try:
                self.poll()
            except Exception:
                log(f"poll:\n{traceback.format_exc()}")
            time.sleep(self.cfg["poll_seconds"])


REBASED = ("Commits after the earlier results commit were rebased without it: update your branch with "
           "`git pull --rebase`.")


def quote(c):
    """The start of a reply to comment `c`: its command, quoted, linked, and its author mentioned."""
    m = COMMAND.search(c["body"] or "")
    command = f"/benchmark {m.group(1).strip() if m else ''}".strip()
    return f"> [{command}]({c['html_url']})\n\n@{c['user']['login']} "


def describe(job):
    benches = ", ".join(f"{b.split('_', 1)[1][:-5]}" + (f" ({', '.join(cs)})" if cs else "") for b, cs in job["benchmarks"])
    return f"{', '.join(job['systems'])} on {benches}"


def not_ok(rows):
    """The queries and runs of the table's rows that were not ok, folded away; empty if there are none."""
    lines = [f"- {s} / {config}: `{q['query']}` {q['status']}" + (f": {q['message'][:200]}" if q.get("message") else "")
             for s, config, sm, _ in rows for q in sm["queries"] + sm["failed"] if q["status"] != "ok"]
    return details(f"Not ok ({len(lines)})", "\n".join(lines[:100]) + ("\n- ..." if len(lines) > 100 else "")) if lines else ""


def details(summary_, text):
    return f"<details><summary>{summary_}</summary>\n\n```\n{text}\n```\n</details>\n" if text else ""


def update_index(repo, env, changes):
    """Apply [(mode, blob, path)] (blob None: removed) to the index of $GIT_INDEX_FILE; no working tree needed."""
    if changes:
        git(repo, "update-index", "--index-info", env=env,
            input="".join(f"{mode} {blob}\t{path}\n" if blob else f"0 {'0' * 40}\t{path}\n" for mode, blob, path in changes))


def sh(cmd, check=False):
    r = subprocess.run(cmd, capture_output=True, text=True)
    if check and r.returncode:
        raise RuntimeError(f"{' '.join(cmd)}: {(r.stdout + r.stderr).strip()[-2000:]}")
    return r.stdout


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--config", default="~/.config/dbo-bot/config.toml")
    a = ap.parse_args()
    cfg = dict(DEFAULTS, **tomllib.load(open(os.path.expanduser(a.config), "rb")))
    for key in ("app_id", "installation_id"):
        if not cfg[key]:
            sys.exit(f"{a.config}: {key} is not set")
    Bot(cfg).main()


if __name__ == "__main__":
    main()
