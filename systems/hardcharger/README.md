# Hardcharger

[Hardcharger](https://github.com/gizmodata/hardcharger) 2.14.0 runs on its own engine,
[Hardcharger Engine](https://github.com/gizmodata/hardcharger-engine) v2.0.1, a fork derived from
DuckDB 2.0.1 and modified for performance
([changes and benchmark notes](https://github.com/gizmodata/hardcharger-engine/blob/v2.0.1/docs/optimizations.md)),
and serves it through [Chargewire](https://github.com/gizmodata/chargewire). `install` uses the
[official Hardcharger installer](https://gizmodata.com/hardcharger/install), pinned to
`HARDCHARGER_VERSION` (2.14.0), to install the server under `/opt/hardcharger`; the installer
selects the architecture, verifies the release checksums and checks the binaries before making
them current. JSON and Parquet support are compiled into the server; the run needs no network
access or extension downloads.

The query program is a client of the server through the
[Hardcharger ADBC driver](https://github.com/gizmodata/hardcharger-adbc) 2.7.2 (`ADBC_VERSION`),
installed by [GizmoData's ADBC installer](https://github.com/gizmodata/adbc-install), which
verifies the release's `SHA256SUMS` and writes the driver manifest
`/etc/adbc/drivers/hardcharger.toml`. Apache Arrow's Rust driver manager (`adbc_driver_manager`)
loads the driver by that name. The program keeps one ADBC database and one connection, so one
server session, for the whole run; every statement is a new ADBC statement on that connection,
sent unchanged. The result arrives as Arrow record batches over the C Data Interface, in one
stream (`hardcharger.query.result_partitions = 1`), and Arrow's CSV writer turns it into
headerless CSV with an empty NULL, as the DuckDB entry does. At a timeout the runner's timer
thread cancels the running statement through ADBC's `StatementCancel`, which sends Chargewire's
cancel request for that statement; the program answers the next request only after the cancel
returned.

The server is bound to loopback, without TLS, inside the runner's isolated container, with
role-based access control off (its default). Its initial engine thread count and memory limit
follow `DBO_THREADS` and 80% of `DBO_MEMORY_MB`; the session settings use the same limits and
dialect as the DuckDB entry. Session idle eviction is disabled so the session survives between
requests. No query result cache, query rewrites, extra tables, indexes or precomputed answers are
used.

`hardcharger-parquet` is this system on the Parquet files in place, as `duckdb-parquet` is
DuckDB's: every table is a view over its files so far, and the Parquet metadata cache is on.

From the repository root:

```sh
cargo build --release --locked -p dbo-bench
./target/release/dbo-bench render --system hardcharger --out rendered/hardcharger
./target/release/dbo-bench run --benchmark bench/benchmark_sf1.toml --system hardcharger --config sf1-c8a.2xlarge --keep
```

The full runner requires Linux and the host setup in `docs/RUNNER.md`.
