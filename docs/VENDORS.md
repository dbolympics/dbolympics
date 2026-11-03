# Adding a database system

A system is a self-contained directory `systems/<name>/`: a system file, the scripts that
install and start it, and its query program, through which the runner talks to it. The runner
builds an image from the directory, starts it with the configured cores and memory, creates the
schema, loads the data, runs the queries and measures them. This is the short path;
[RUNNER.md](RUNNER.md) has every field and rule, [systems/README.md](../systems/README.md) the
directory's files and the protocol.

## Steps

1. **Copy a directory that is close to your system:**
   - `umbra`, `cedardb` or `postgres`: a container image, PostgreSQL protocol;
   - `firebolt`: a container image, HTTP;
   - `hyper`: a server installed in the container, PostgreSQL protocol;
   - `clickhouse`: a server installed in the container, HTTP;
   - `duckdb`, `chdb` or `datafusion`: an engine embedded in its query program.
2. **`query.rs`** (with `Cargo.toml`, `Cargo.lock`): the query program, in Rust. Change the part
   at the top (`System`: connect, run a statement; `Cancel`: cancel the running one); `main`
   hands them to `dbo::serve` ([systems/dbo](../systems/dbo/README.md)), which has the
   protocol, the loop and the timer.
3. **`install`**: install the system and build the query program to `/system/query` (copy the
   build at the end of another `install`). It runs once, as root, on Ubuntu 26.04, with network,
   in `/system`. Pin the versions.
4. **`start`, `stop`**: start the system's servers (if any) and then the query program in the
   background, its output to `/run/dbo/query.log`; stop them. Most systems size themselves for
   the container; check that yours does. Only if it does not (it sees the host's memory, or has
   fixed defaults), size it from `DBO_THREADS` and `DBO_MEMORY_BYTES` (or `DBO_MEMORY_MB`)
   ([RUNNER.md](RUNNER.md#containers), Limits).
5. **`system.toml`**: the load statement for a Parquet file, the SQL spellings that differ from
   the defaults ([RUNNER.md](RUNNER.md#dialects)), type names, session settings, any
   container that has to run next to the system's own, and under `[site]` the name and a few
   words on how it runs, as the website shows them.
6. **Try it:**

```bash
./target/release/dbo-bench render --system <name> --out rendered/<name>   # what the system gets
./target/release/dbo-bench run --benchmark bench/benchmark_sf1.toml --system <name> --config sf1-c8a.2xlarge --keep
```

   `bench/out/<date>/sf1-c8a.2xlarge/<name>/errors.log` then has the error of every failed
   statement and the differences of every wrong result.

## Rules

Details in [RUNNER.md](RUNNER.md).

- **Same schema for everyone:** only type names and a `CREATE TABLE` suffix may differ; no
  indexes beyond the primary keys of `keys = "primary"`, no other tables.
- **The system loads the Parquet files itself** from `/data` (`/data-arrays` with
  `arrays = "text"`), in the order the runner asks.
- **The SQL is passed through unchanged;** dialect differences go in `system.toml`.
- **One connection, one process for the run:** nothing starts per statement; an embedded engine
  lives in its query program.
- **No result caches:** queries repeat on unchanged data.
- **Self-contained directory:** nothing from elsewhere in the repository but `systems/dbo`; no
  network after `install`.
- **Timeouts are the system's job,** through its query program: a query still running after its
  timeout and the grace period fails the run, and so does a load over its timeout.
