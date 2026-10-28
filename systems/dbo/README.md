# dbo: what every query program shares

A small Rust library (`lib.rs`, no dependencies) that serves the runner's protocol
([../README.md](../README.md#the-runners-protocol)) for every query program, so that a system's
`query.rs` only connects, runs a statement and cancels one. The feature `pg` adds the PostgreSQL
protocol (`pg.rs`, on `tokio-postgres`). It has no `system.toml`, so the runner does not run it.

## What is in it

| Item | What it does |
|---|---|
| `serve(run, cancel)` | serves the runner's protocol on `/run/dbo/dbo.sock` for the whole run: reads a request, calls `run(sql, timeout_ms)`, starts a timer that calls `cancel()` at the deadline, writes the answer. When the runner closes the connection it waits for the next one; it never ends by itself (`stop` or the end of the container does) |
| `retry(connect)` | calls `connect` until it succeeds, every 100 ms (the system may still be starting); prints each new error once, to `query.log` |
| `csv_field(out, value)` | appends one CSV field: NULL (`None`) as nothing, the empty string as `""`, quoted when it holds `,` `"` or a line break |
| `SOCKET` | `/run/dbo/dbo.sock` |
| `pg::Pg` (feature `pg`) | one connection over the PostgreSQL protocol, for the run: `connect(connection string)` (with `retry`), `query(sql)` (the messages, or the system's error message), `run(sql)` (the rows as CSV), `canceller()` |
| `pg::PgCancel` | `cancel()`: the cancel request on a new connection, then a wait until the system closes it, as libpq (see below) |
| `pg::csv`, `pg::lines` | a result's rows as CSV; its first column as lines (the query an `EXPLAIN` wrote) |

A query program looks like this (`../duckdb/query.rs`):

```rust
struct System(Connection);            // the connection, or the embedded engine
struct Cancel(Arc<InterruptHandle>);  // what another thread needs to cancel the running statement

impl System {
    fn connect() -> (System, Cancel) { ... }
    fn run(&mut self, sql: &str, timeout: u32) -> Result<Vec<u8>, String> { ... }   // CSV or the error
}
impl Cancel {
    fn cancel(&self) { ... }
}

fn main() {
    let (mut system, cancel) = System::connect();
    dbo::serve(|sql, timeout| system.run(sql, timeout), || cancel.cancel());
}
```

A system that speaks the PostgreSQL protocol needs only its connection string
(`../hyper/query.rs`):

```rust
const CONNECT: &str = "host=127.0.0.1 port=7483 user=postgres dbname=/system/db/dbo.hyper";

fn main() {
    let mut pg = dbo::pg::Pg::connect(CONNECT);
    let cancel = pg.canceller();
    dbo::serve(|sql, _timeout| pg.run(sql), || cancel.cancel());
}
```

## The timer

For each statement `serve` starts a timer thread, which waits on a channel for at most the
timeout, and runs the statement itself on the thread that reads the requests. If the statement
ends first, `serve` drops the channel's sender and the timer ends; if the deadline comes first,
the timer calls `cancel()` and reports the statement late. `serve` joins the timer before it
answers; a late statement is a timeout (status 2), whatever it then returned.

Why:

- **A scoped thread** (`std::thread::scope`) per statement, joined before the answer. The timer can
  only ever cancel the statement it was started for, never the next one, and it can borrow `cancel`
  without an `Arc` or `'static` closure. This is why `cancel` only needs to be `Fn() + Sync`.
- **An `mpsc` channel with `recv_timeout`** as the timer: the thread ends as soon as the
  statement does, without polling.
- **The timeout as an argument to `run`**, not only to the timer. Systems that cannot be cancelled
  from another thread (chDB, Firebolt) set their own limit, a second over the deadline, so that the
  timer still decides.
- **Errors are values, I/O failures panic.** A failing statement is an answer (status 1). If the
  socket or the request breaks, the program panics and the runner sees the closed connection as a
  crash.

What the system's part must do:

- **`cancel`** must return quickly and leave the connection usable: the next request follows at
  once. Examples: a cancel request on a new connection (the PostgreSQL protocol), `KILL QUERY` on
  another connection (ClickHouse), an interrupt handle (DuckDB), a `Notify` that ends the
  running future (DataFusion).
- **A cancel must have taken effect before `cancel()` returns.** The answer follows right after,
  then the next statement; a cancel the system takes only then cancels that one. Over the
  PostgreSQL protocol the system takes a cancel request when it reads it (PostgreSQL ignores it
  while the connection is idle, Umbra marks the transaction running then) and then closes the
  cancel connection. libpq waits for that close; the `postgres` crate does not, so a statement
  that ended just at its deadline could cancel the next one. `pg::PgCancel` waits.

## How it gets into an image

The system's directory is copied to `/system` and this one to `/dbo` (`bench/src/podman.rs`), so
`Cargo.toml` names it by the same relative path in the repository and in the image:

```toml
dbo = { path = "../dbo" }
```

A change to the code here rebuilds every system's image (this README is left out).

## Testing

`cargo test` here tests the CSV quoting. The protocol and the timer are tested by every run,
which first checks that the system cancels a query at its timeout and answers the next one
(`timeout_check` in the run's record).
