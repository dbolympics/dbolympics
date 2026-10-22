# Hardcharger

[Hardcharger](https://github.com/gizmodata/hardcharger) 2.0.0 serves DuckDB 2.0.0
through Warp SQL. `install` downloads the released server and `hardcharger` CLI,
checks their archive's SHA-256, and builds the runner adapter with a pinned Rust
toolchain and lockfile. JSON and Parquet support are compiled into the server;
the run needs no network access or extension downloads.

Every benchmark statement is sent unchanged to **one persistent `hardcharger`
CLI process**, using one database session for the whole run. The CLI produces
headerless CSV with an empty NULL representation and no row limit. `.once`
redirects each result to a file which is closed after the statement; `.echo`
provides a local completion barrier. Neither command executes SQL or launches a
subprocess. The adapter returns the CLI's CSV or its error text to `dbo::serve`.
Update acknowledgements are ignored by the runner, as for other systems.

At startup, the CLI identifies its own session with
`SELECT session_id FROM hardcharger_active_connections() WHERE is_current`.
The adapter authenticates a separate HTTP **control channel**, used only to send
Warp SQL's session-cancel request at a timeout. Waiting for its acknowledgement
and the CLI's completion barrier keeps cancellation from reaching the next
statement. All schema creation, data loading and benchmark queries go through the
CLI; the control channel never executes SQL. This also avoids sending SIGINT to
a noninteractive CLI after the server has finished and CSV formatting has begun.

The server is bound to loopback, without TLS, inside the runner's isolated
container. Its initial DuckDB thread count and memory limit follow `DBO_THREADS`
and 80% of `DBO_MEMORY_MB`; the session settings use the same limits and dialect
as the DuckDB entry. The CLI requests one result stream. Session idle eviction is
disabled so the original session survives between requests. No query result
cache, query rewrites, extra tables, indexes or precomputed answers are used.

From the repository root:

```sh
cargo build --release --locked -p dbo-bench
./target/release/dbo-bench render --system hardcharger --out rendered/hardcharger
./target/release/dbo-bench run --benchmark bench/benchmark_sf1.toml --system hardcharger --config sf1-c8a.2xlarge --keep
```

The full runner requires Linux and the host setup in `docs/RUNNER.md`.
