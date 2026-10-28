#!/usr/bin/env python3
"""The check of a pull request (.github/workflows/systems.yml): which systems it changes, whether the benchmark bot
may run it, and that the bot's results commit is the last one and of the code as it is. See docs/BOT.md.

    python3 tools/bot/check_pr.py --repo-dir PR --main origin/main --head HEAD [--fork-owner Organization]

--fork-owner is the type of the account that owns the pull request's repository if that is a fork (User or
Organization), empty for a branch of the repository itself.

Writes the systems to $GITHUB_OUTPUT (systems=...) and a summary to $GITHUB_STEP_SUMMARY when they are set; fails
(exit status 1) on an error.
"""
import argparse
import os
import sys
import tomllib

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from common import (ORGANIZATION_FORK, changed_systems, git, missing_files, problems, split, stale, SYSTEM_NAME,  # noqa: E402
                    user_results)


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--repo-dir", default=".")
    ap.add_argument("--main", default="origin/main")
    ap.add_argument("--head", default="HEAD")
    ap.add_argument("--fork-owner", default="")
    a = ap.parse_args()
    repo, head = a.repo_dir, git(a.repo_dir, "rev-parse", a.head)
    errors, notes = [], []
    if a.fork_owner == "Organization":
        errors.append(ORGANIZATION_FORK)

    base, results, tip = split(repo, a.main, head)
    systems, shared = changed_systems(repo, base, tip)
    if results:
        r = results[-1]
        if len(results) > 1 or r != head:
            errors.append("The bot's results commit is not the last commit: a maintainer moves it to the end with "
                          "`/benchmark move`, or runs the benchmark again with `/benchmark`.")
        elif old := stale(repo, r, tip):
            errors.append(f"The results of {', '.join(old)} are of older code: the system changed after the run. "
                          "A maintainer runs the benchmark again with `/benchmark`.")

    # results of the pull request's own: what differs from the merge base, but the files of a last results commit
    bots = set(git(repo, "diff-tree", "-r", "--no-commit-id", "--name-only", head).splitlines()) if results == [head] else set()
    if own := [f for f in user_results(repo, base, head) if f not in bots]:
        notes.append("The pull request changes results (" + ", ".join(f"`{f}`" for f in own[:10])
                     + (" ..." if len(own) > 10 else "") + "): the bot's results commit undoes that.")

    for error, p in problems(repo, a.main, base, tip):
        (errors if error else notes).append(p if error else f"The bot does not run this pull request: {p}")
    if shared:
        notes.append("The pull request changes `systems/dbo`, which every system uses: the bot does not run it, "
                     "the benchmark is run by hand.")
    for s in systems:
        if not SYSTEM_NAME.match(s) or git(repo, "ls-tree", tip, "--", f"systems/{s}/") == "":
            continue  # a bad name is an error above; a removed system has nothing to check
        if miss := missing_files(repo, tip, s):
            errors.append(f"`systems/{s}` is missing {', '.join(miss)}.")
        try:
            tomllib.loads(git(repo, "show", f"{tip}:systems/{s}/system.toml"))
        except Exception as e:  # missing (reported above) or not TOML
            errors.append(f"`systems/{s}/system.toml`: {e}")

    out = [f"**Changed systems:** {', '.join(f'`{s}`' for s in systems) or 'none'}"]
    if systems:
        out.append("A maintainer of the repository can run them on our server by commenting `/benchmark`.")
    out += [f"- {n}" for n in notes] + [f"- **Error:** {e}" for e in errors]
    print("\n".join(out))
    if os.environ.get("GITHUB_STEP_SUMMARY"):
        open(os.environ["GITHUB_STEP_SUMMARY"], "a").write("\n".join(out) + "\n")
    if os.environ.get("GITHUB_OUTPUT"):
        ok = [s for s in systems if SYSTEM_NAME.match(s) and git(repo, "ls-tree", tip, "--", f"systems/{s}/system.toml")]
        open(os.environ["GITHUB_OUTPUT"], "a").write(f"systems={' '.join(ok)}\n")
    for e in errors:
        print(f"::error::{e}")
    sys.exit(1 if errors else 0)


if __name__ == "__main__":
    main()
