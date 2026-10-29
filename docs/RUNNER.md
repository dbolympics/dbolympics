# Benchmark runner

How dbolympics runs a database system: the benchmark file, the procedure, what is measured,
how a system is described, and how its containers are set up. The runner is in `bench/`, the
systems in `systems/` ([systems/README.md](../systems/README.md)). Adding a system is described
in [VENDORS.md](VENDORS.md).

## Running it

```bash
bench/host-setup.sh                      # once per machine, needs sudo (see Host setup)
cargo build --release --workspace        # generator and runner
./target/release/dbo-bench run --benchmark bench/benchmark_sf1.toml     # every system, every configuration
./target/release/dbo-bench run --benchmark bench/benchmark_sf1.toml --system duckdb --config sf1-c8a.2xlarge
```

- **Requirements:** Linux, rootless Podman, Rust, the host setup below.
- **Datasets** are generated on demand into `data/sf<sf>`.
- **Results** go to `systems/<system>/results/<date>/<config>.csv` and `<config>.json`; the rest
  of a run goes to `bench/out/<date>/<config>/<system>/` (see Results).

| Command | What it does |
|---|---|
| `run --benchmark <file>` | run the benchmark; `--system`, `--config` select (repeatable) |
| `run --keep` | keep every run's directory in `bench/out/`, not only those of failed runs |
| `run --no-build` | run the images as they are (built before, or `podman save`/`load`ed from another machine) |
| `run --checks-only` | only start every system and check that it cancels a query at its timeout; no results |
| `images [--benchmark <file>] [--system ...]` | build the systems' images (all without `--benchmark`) and pull their other containers' images, so that a run starts without building |
| `render --system <name> --out <dir>` | write the schema and queries as the system gets them (`--keys`, `--mark`, `--queries`: see `--help`) |
| `points` | print the dialect customization points as JSON |
| `check <expected> <actual>` | compare results (files or directories of `q*.csv`) by value |
| `references <run dir>` | make a run's results (kept with `--keep`) the reference results of its scale factor |

## The benchmark file

A benchmark file (`bench/benchmark_sf1.toml`, `_sf10`, `_sf100`, `_sf1000`: one per scale factor,
on AWS c8a instance shapes) describes the benchmark and the system configurations to test:

```toml
repetitions   = 1               # runs of all queries after every load
query_timeout = 5               # seconds per query
load_timeout  = 300             # seconds per load (optional)
grace_period  = 5               # seconds past a query's timeout before the run fails as stuck
keys          = "none"          # "none" or "primary"

[[config]]
name          = "sf10-c8a.4xlarge"
sf            = 10
threads       = 16
memory        = "32GB"
```

| Field | Meaning |
|---|---|
| `systems` | directories below `systems` (optional: without it, every one with a `system.toml`) |
| `repetitions` | how often all queries run after every load |
| `query_timeout` | seconds per query: the system cancels a query at it (`timeout`) |
| `load_timeout` | optional: seconds for each of the five loads, all its statements together. Each load statement gets what is left of it as its timeout; past it the run fails at once, without a grace period (`failed_load_timeout`) |
| `grace_period` | seconds the runner waits past a query's timeout for the system's answer; after it the run fails (`failed_stuck`) |
| `keys` | `none`: tables without keys; `primary`: with primary keys. Foreign keys are never declared |
| `queries` | a subset, e.g. `["q001-q020", "q100"]` (default: all 409) |
| `[[config]]` | a system configuration; every system runs once per configuration |
| `name` | names the result file |
| `sf` | scale factor of the dataset |
| `threads` | the system is pinned to this many cores (the first ones, or `cpuset = "8-15"`) |
| `memory` | memory limit of the system (`"64GB"`, binary units) |
| `keys`, `query_timeout`, `load_timeout`, `grace_period` (in a config) | override the benchmark's |

## Procedure

For every configuration and every system, on a fresh system (new containers, no data):

1. **Start** the system with its `start`, which also starts its query program, and wait until
   `SELECT 1` answers through the query program. Then check that it cancels a query at its
   timeout: a recursive count to 10^12 with a timeout of a second, and `SELECT 1` after it
   (after the session settings). A system that does not answer after the cancel fails the run
   (`failed_setup`); the outcome is `timeout_check` in the run's record.
2. **Settings and schema**: the session settings of the system file, then the same tables for
   every system, rendered from `schema/schema.json` (column names double-quoted); a system may
   only change type names and append text to `CREATE TABLE`.
3. **Load** `2024-and-earlier`: every table's file of that period, one statement per table, one
   after the other; the load's time is their sum (run 1).
4. **Run all queries** `repetitions` times, in query order.
5. **Load the next quarter** of 2025 and run all queries again (run 2), and so on until
   `2025-Q4` is loaded: five runs.
6. **Check**: in the last repetition of the last run, every result is saved and compared by
   value with the reference results (`workload/results/sf<sf>/through-2025-Q4/`). Without
   reference results for the scale factor the results are marked `unchecked`.
7. **Stop** the system and remove its containers with everything they wrote.

Rules:
- **The system lives for the whole run.** It is never restarted, so its caches stay warm. The
  runner keeps one connection to its query program, and the query program one to the system:
  no process starts and no connection opens per statement.
- **A query over the timeout** is cancelled by the system, recorded as `timeout`, and left out
  for the rest of that run (it is tried again after the next load). The same holds for a query
  that fails (`error`).
- **A run fails as a whole** when the system is killed for memory (`failed_oom`), stops
  answering (`failed_crash`: the connection closes, or `SELECT 1` fails after an error), does not
  answer a query within its timeout and the grace period (`failed_stuck`: the runner kills the
  containers), cannot load a file (`failed_load`), takes longer than `load_timeout` for a load
  (`failed_load_timeout`: the runner kills the containers at the timeout) or cannot be set up
  (`failed_setup`). The runner then goes on with the next system.
- **Loading is in time order**, one period per load. A file without rows is skipped.

## Data

- **One file per period** for every table: `data/sf<sf>/<table>/<period>.parquet`, with the
  periods `2024-and-earlier` (the rows from before the 2023 migration, and those of 2023 and
  2024) and `2025-Q1` ... `2025-Q4` ([SIMULATOR.md](SIMULATOR.md), Output).
- **Parquet only.** Systems load the files themselves from `/data`, which is mounted
  read-only in every container.
- **Array columns:** four tables have them (`personal_access_tokens`, `webhooks`,
  `change_history`, `access_log`). A system that cannot read Parquet lists sets
  `arrays = "text"` and gets these tables from `/data-arrays`, with the arrays as PostgreSQL
  array literals in text (`{"a","b"}`); the runner makes that copy once.

## What is measured

- **Times are the runner's own**, from sending a statement to having the whole answer; a load's
  time is the sum of its tables' statements. They include the query program and the transfer of
  the result, and nothing the system reports itself.
- **Storage size** (what the containers wrote) and **peak memory** of the pod (all its
  containers together) are in `run.json`.

## Results

`systems/<system>/results/<date>/<config>.csv` has one row per run and query:

```csv
run,loaded,query,median_s,status,message
1,2024-and-earlier,load,5.409272,ok,
1,2024-and-earlier,q001,0.005916,ok,
5,2025-Q4,q017,,timeout,no result within 5 s
```

| Column | Meaning |
|---|---|
| `run` | counter of the load: 1 is the load of `2024-and-earlier`, then one per quarter of 2025 |
| `loaded` | the last period in the database |
| `query` | the query, or `load` |
| `median_s` | seconds: the median over the repetitions; for `load` the time of the load |
| `status` | `ok`, `timeout`, `error`; in the last run also `wrong_result` and `unchecked`; `failed_*` on the last row of a failed run; `not_supported` when the system cannot run the configuration's `keys` |
| `message` | why there is no correct result, in the system's words: the error's key line, the time limit for a timeout, the first difference from the reference result for a wrong result, what ended a failed run; empty for `ok` |

- A query that did not finish every repetition has its status and no time.
- A failed run keeps the rows it finished and ends with a `failed_*` row that names the run
  and the query it failed at.
- Running a system again on the same day replaces its rows; other systems' rows stay.

`<config>.json` next to it is the run's `run.json` and says what ran, so that the results never
depend on a benchmark file that may have changed since: the configuration (`sf`, `threads`,
`cpuset`, `memory`, `query_timeout`, `load_timeout`, `grace_period`, `repetitions`, `keys`,
`queries`), the benchmark file, the commit of the repository (`dirty` if a tracked file outside
the results differed from it), the host (CPU model, CPUs, memory, kernel), the images of the
containers (the registry digest of a pulled image, the ID of a built one), the system's
`version`, and the outcome (`complete`, `failure`, `storage_bytes`, `memory_peak_bytes`). The
website shows each system's latest run per configuration.

`bench/out/<date>/<config>/<system>/` has the rest while the run goes on; the runner keeps it
only if the run failed, or with `--keep`:

| File | Content |
|---|---|
| `times.csv` | every execution: run, repetition, query, seconds, status |
| `load.csv` | every load: the tables it loaded, rows, seconds |
| `results/qNNN.csv` | the results of the last execution |
| `errors.log` | error texts, differences to the reference results, the query program's and the containers' logs after a crash |
| `query.log`, `start.log`, `stop.log` | what the query program and the scripts wrote |
| `Containerfile` | how the system's image was built |
| `run.json` | what ran and the outcome, as `<config>.json` above |

## A system directory

The files of `systems/<name>/` and the protocol its query program speaks are in
[systems/README.md](../systems/README.md). `install`, `start` and `stop` run as root in
`/system`, the system directory in the image, with `DBO_THREADS`, `DBO_MEMORY_BYTES` and
`DBO_MEMORY_MB` in the environment.

**The system file:**

```toml
name = "umbra"
version = "experimental"   # the version, set by hand, kept with the results: without the
                           # name; another database it needs in parentheses
arrays = "text"                # default "native"
keys = ["none", "primary"]     # the `keys` settings the system can run (default: both)
scale_limit = 1000             # disabled from this scale factor on (default: never): a configuration
                               # at or above it is skipped, no results written
scale_limit_message = "..."    # why, shown on the website in place of any results there

[load]
statement = "COPY {table} FROM '{file}' WITH (FORMAT parquet)"   # once per table and load

[ddl]
suffix = ""                    # appended to every CREATE TABLE
suffix_without_keys = ""       # the same for keys = "none" (default: suffix)

[dialect]
settings = []                  # session statements, sent once before the schema
[dialect.functions]            # SQL spellings, see Dialects
[dialect.types]

[[container]]                  # a container started next to the system's own
name = "db"
image = "docker.io/umbradb/umbra:experimental"   # pulled unless the image exists
env = { PARALLEL = "{threads}", MEMORY = "{memory_mb}M", PGHOST = "/run/dbo" }
ulimits = ["nofile=524288:524288"]
user = "root"                  # the user in the container instead of the image's (default: the image's)
data_writable = false          # see below
```

- **Placeholders** in a container's `command` and `env` and the settings: `{threads}`,
  `{memory_bytes}`, `{memory_mb}`, `{memory_gb}`; `{memory_mb%45}` is 45 percent of the value.
- **`data_writable`** mounts the data writable in that container, for a system that only
  opens files for writing. The runner then compares size and modification time of every data
  file before and after the run and fails the run if one changed.
- **`scale_limit`** is set only where the system itself is the limit (a license, a load that
  takes hours), not for a bug: a system that gets stuck or crashes on a query keeps running,
  since that is a finding.
- **A moving image tag** (Umbra's `experimental`, used by `umbra`, `pg_brew` and
  `clickhouse_brew`) is fine: the run's record keeps the digest of the image that ran.

## Dialects

The canonical queries are standard SQL with `{{...}}` placeholders where systems differ. The
points, their defaults and where a difference goes are in [DIALECTS.md](DIALECTS.md). In
`system.toml`:

- **`[dialect.functions]`**: a template per point that differs from the default, keyed by the
  point: `"add_minutes(ts, n)" = "addMinutes({ts}, {n})"`.
- **`[dialect.types]`**: type names of the schema: `bigint`, `integer`, `smallint`, `boolean`,
  `date`, `timestamp`, `uuid`, `json`, `double`, `varchar(length)`, `decimal(precision, scale)`,
  `array(element)`. A decimal keeps the schema's precision and scale: its template must contain
  `{precision}` and `{scale}` (e.g. `"Decimal({precision}, {scale})"`).
- **`settings`**: session statements, only to follow the standard more closely
  ([DIALECTS.md](DIALECTS.md), Settings).

## Containers

- **One pod per run**, made with rootless Podman: the system's own container, and the
  containers of its system file. They share the pod's network (loopback only, no way out),
  so the query program reaches a database in another container at `127.0.0.1`.
- **Sockets:** a host directory is `/run/dbo` in every container of the pod. The query program
  makes its socket (`dbo.sock`) and log (`query.log`) there, and the runner connects from the
  host; a system that can puts its own socket there too (Unix sockets where a system has them,
  TCP otherwise).
- **The system's own container** is built from `bench/image/Containerfile` (Ubuntu 26.04 with
  a few tools), the system directory copied to `/system`, and its `install` run there. Podman
  caches the layers: `install` runs again only when a file of the directory changes; its
  results (`results/`) and a local Rust build (`target/`) are left out of the image. Building
  needs network; runs have none.
- **Storage:** nothing is mounted for storage; a system writes into its container's own
  filesystem. Podman's storage is `bench/containers/` (remove it by hand with
  `podman unshare rm -rf bench/containers`). Before a configuration starts and after it ends,
  every pod, container and volume of it goes, the databases' files with them (the images stay);
  a storage that cannot be emptied stops the run.
- **Limits:**
  - **Cores:** every container is pinned to the configuration's cores (`--cpuset-cpus`).
  - **Memory:** every container has the configuration's memory as its own limit (a system with
    two databases in two containers, as the brew systems, has it twice; the pod has none). The
    limit counts everything, the file cache included; there is no swap. The kernel gives file
    cache back before it kills, so only memory a system really holds can get it killed. A kill
    takes the whole container (`memory.oom.group`) and fails the run.
  - **What the system sees:** LXCFS files are mounted over `/proc/meminfo`, `/proc/cpuinfo`,
    `/proc/stat` and `/sys/devices/system/cpu`, so tools that read them see the limits.
    - **Sizing itself:** most systems size themselves for the container from these files and the
      cgroup, so they get no limits of their own. These are DuckDB, ClickHouse, chDB,
      Hyper, CedarDB and Firebolt, and DataFusion's threads; each was checked in a limited
      container.
    - **Explicit limits:** a system that does not size itself gets its limits explicitly, from
      the `DBO_*` variables or placeholders:
      - Umbra's memory: it sizes itself for the host's memory and is killed. Its threads it
        finds itself, but it gets them explicitly too, until its memory is fixed.
      - DataFusion's memory pool: it has no limit by default.
      - PostgreSQL's settings: its defaults are fixed numbers, whatever the machine.
- **io_uring** is allowed: `bench/seccomp.json` is Podman's default seccomp profile plus the
  three io_uring calls. Locked memory is unlimited in the containers.

## Host setup

`bench/host-setup.sh` (once, with sudo):
- installs and starts **LXCFS**;
- lets the user's containers be pinned to cores (**cpuset delegation**, a systemd drop-in for
  `user@.service`);
- lifts the user's limit on **locked memory** (`/etc/security/limits.d`).

The last two fully apply to new logins. In a session from before, the runner lifts its own
limit through `sudo prlimit`.
