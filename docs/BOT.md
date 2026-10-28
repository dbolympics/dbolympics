# The benchmark bot

A pull request that adds or changes a system is benchmarked on our server when a maintainer asks for it. The
results become the pull request's last commit, so that they are reviewed with it.

1. **The check** (`.github/workflows/systems.yml`, `tools/bot/check_pr.py`) runs on every pull request. It lists the
   systems the pull request changes, renders their queries, and fails if:
   - the bot's results commit is not the last commit, or
   - the results are of older code of a system than the pull request has.

   It also notes results the pull request changes itself, which the bot's results commit undoes.
2. **A maintainer comments** `/benchmark` on the pull request. A maintainer is anyone with the `maintain` or `admin`
   role in the repository. Others get a reply, once per pull request, that they cannot start a run.
3. **The bot** (`tools/bot/bot.py`, on the server as the user `dbolympics`) polls GitHub for such comments, runs
   the systems, comments each system's table of results when it is done, adds the results commit, and replies to
   the comment.

## Commands

| Comment | What the bot does |
|---|---|
| `/benchmark` | runs the systems the pull request changes on all benchmark files, `bench/benchmark_sf{1,10,100,1000}.toml` |
| `/benchmark duckdb sf10` | runs the named systems on the named benchmark files |
| `/benchmark sf1-c8a.large` | runs only that configuration of the file |
| `/benchmark @1a2b3c4` | runs only if the pull request is at that commit |
| `/benchmark move` | moves the results commit to the end again, without running anything |
| `/benchmark cancel` | stops the pull request's run, or takes it out of the queue |
| `/benchmark status` | replies with what runs, what waits, and who holds the machine |

Each command goes at the start of a line. Edited comments do not count.

## A run

1. **Approval.** The bot takes the pull request as it is when it reads the comment. If commits arrive before the run
   starts, it refuses, and the maintainer approves again.
2. **Checks.** The bot runs the pull request's systems on main: main's files, with the directories of the systems
   the pull request changes as they are in it. So it needs no rebase when main has moved on, but:
   - The pull request may change nothing outside its systems' directories, since that would not be in the run. The
     exceptions are documentation (`*.md`, `docs/`), `site/` and `.github/`, which never run on the server.
   - If main changed one of the pull request's systems since the pull request branched off, the bot asks for a
     rebase onto main: the run would leave main's change out.
   - The systems' own code only runs inside their containers. It may not contain symbolic links or submodules.
   - A pull request from a fork needs "Allow edits by maintainers", and the fork must be a user's: GitHub does not
     let us push the results commit to the branch of an organization's fork. The pull requests' check fails for one.
3. **Build.** `cargo build --release --workspace` runs in the bot's checkout of that tree (a commit on main of the
   bot's own, not pushed), which keeps the generated data and the build from run to run.
4. **The machine.** The bot waits until nobody holds the machine. Then it reserves it with `reserve-machine`, which
   ends the other users' sessions and processes.
   - It schedules `release-machine 24h --kill` at the same time: each system gets 24 hours (`reserve_hours`).
   - Before each further system, it schedules the release again, 24 hours from then. A scheduled release is
     replaced by the new one, so extending always works.
   - If a system is not done within its 24 hours, the machine is released, and everything of `dbolympics` is
     killed: the run, its containers and the bot. systemd starts the bot again, and it replies which system was
     stopped.
   - A run that ends in time releases the machine as soon as it is done, which also cancels the scheduled release.
5. **The run.** One system after the other, each with all its configurations: `dbo-bench run --benchmark …
   --system <system>` once per benchmark file. The output goes to `<work>/logs/<pull request>-<comment>.log`.
6. **The results commit.** The new `systems/<name>/results/<date>/` files become one commit, authored by the bot, on
   top of the pull request's last commit.
   - Earlier results from the last results commit stay, as long as the system's code has not changed: those of the other
     systems, and those of the configurations not run now (`/benchmark clickhouse sf1000` keeps ClickHouse's sf1 to sf100).
   - The commit's trailers name the systems and a hash of each system's code (without its results). That is how the
     check tells whether the results are still of the code as it is.
   - **Results are the bot's.** The commit undoes the pull request's own changes to `systems/*/results/`: files it
     changed go back to how they are where the pull request branched off main, and files it added are removed.
7. **Moving the commit.** If the contributor added commits after an earlier results commit, the bot drops that
   commit and puts the commits after it again on its parent. They keep their authors, dates and messages.
   - A file the old results commit changed is put back as it was before, unless a later commit changed it again.
     The new results commit then undoes those changes too, as it does any of the pull request's results.
   - Unlike a rebase, this cannot conflict.
   - The new results commit is the last one again, and the reply asks the contributor to `git pull --rebase`.
8. **Pushing.** The bot pushes with `--force-with-lease`. A push by the contributor during the run is never
   overwritten: the reply then says the results were not added.
9. **A comment per system.** When a system has run all its configurations, the bot comments its table on the
   pull request, a comment of its own for each system. Per configuration, the table gives:
   - the loads' time;
   - the last run's queries by status;
   - their time and geometric mean;
   - the same numbers from main's newest results, for comparison.

   Below it, folded away, are the queries that were not ok.
10. **The reply** to the approving comment, at the end, links to each system's comment. It says whether the
    results commit was added and which results it undid or kept.

## Installing it on the server

The bot is the GitHub App **DB Olympics Bot** of the organisation (`db-olympics-bot`, app ID
5424697, installed on the repository as installation 174087504).
- **Permissions:** contents, issues, pull requests and workflows with write access; metadata read-only.
  - Workflows is needed because moving the results commit rewrites the contributor's commits, which may change
    `.github/workflows/`.
- **Identity:** it comments and pushes as `db-olympics-bot[bot]`, from a token it gets for an hour at a time. It gets
  the token from a JWT signed with the app's private key, `~/.ssh/db-olympics-bot.pem` on the server.

To install it, or to update it, run this as `dbolympics` on the server, in a clone of main:

```bash
git pull                        # the bot runs the code of this checkout
bench/host-setup.sh --bot
journalctl --user -u dbo-bot -f # its log
```

Besides the host setup every benchmark machine needs, `--bot` does the following:
- **Checks first.** It refuses unless it runs as the bot's user without sudo, and the app's key is there
  (`key_file`). It also refuses while the bot runs a benchmark, since a restart would end the run. All this happens
  before anything changes.
- **The configuration.** It writes `~/.config/dbo-bot/config.toml` from `tools/bot/config.example.toml` the first
  time. After that it leaves the file as it is.
- **The service.** It installs `~/.config/systemd/user/dbo-bot.service`, pointing at this checkout, and turns on the
  user's lingering: the service runs without a login, and rootless podman then needs it.
- **Starting.** It enables the service, (re)starts it, and checks that it runs.

Without `--bot`, nothing of the bot is installed. That is the default for every other machine and user.

## Limits

- **One run at a time.** Further runs wait in the queue. The queue survives restarts (`<work>/state.json`).
- **The bot's user is the bot's alone.** After a run, the bot removes all of the user's containers
  (`podman rm --all`).
- **A pull request's workflow file is its own.** A pull request can change `systems.yml` and pass its own check. The
  bot does not rely on the check: it applies the same rules itself before it runs anything.
