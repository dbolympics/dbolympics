# Systems

One directory per database system, self-contained: it uses nothing from the repository but
`dbo/`, the library every query program shares ([dbo/README.md](dbo/README.md)). How to add one:
[docs/VENDORS.md](../docs/VENDORS.md); the reference: [docs/RUNNER.md](../docs/RUNNER.md).

| File | Purpose |
|---|---|
| `system.toml` | the dialect, the load statement, other containers, the name and description on the website ([RUNNER.md](../docs/RUNNER.md#a-system-directory)) |
| `install` | installs the system and builds its query program to `/system/query`; runs once, when the image is built (again when a file of the directory changes) |
| `start` | starts the system's servers (if any) and its query program, in the background |
| `query.rs`, `Cargo.toml`, `Cargo.lock` | the query program: serves the runner's protocol (below) and runs the statements on the system, or holds it embedded |
| `stop` | optional: stops the query program and the servers |
| `logo.svg` | optional: the system's mark on the website, fitted into 16 x 16; `currentColor` is the text colour, `var(--paper)` the background. Not in the image |

The query programs use the system's own Rust client (`dbo::pg` for the PostgreSQL protocol,
`ureq` for HTTP, the embedded engines' crates). The part at the top connects, runs a statement
and cancels one; `main` hands these to `dbo::serve`.

## The runner's protocol

The query program runs for the whole run. It connects to the system (waiting while the system
starts), keeps that one connection, then listens on the Unix socket `/run/dbo/dbo.sock`; `start`
sends what it writes to `/run/dbo/query.log`. The runner connects once and sends one statement
at a time, waiting for each answer. Integers are little-endian.

- **Request:** `u32` length of the rest, `u32` timeout in milliseconds (0: none), then one SQL
  statement (UTF-8). Settings, the schema, the loads (one statement per table) and the queries
  all come this way.
- **Response:** `u32` length of the rest, `u8` status, then:

| Status | Meaning | Follows |
|---|---|---|
| 0 | ok | the result as CSV: no header, NULL as an empty field, the empty string as `""` (ignored for a statement that is not a query) |
| 1 | error | the system's error text |
| 2 | timeout | nothing |

At the deadline the query program cancels the statement from a second thread; a statement that
then ends, as an error or not, is a timeout, and the system must answer the next request as
usual. The runner measures from sending the request to having the response. The SQL is passed
through as it comes: dialect differences go in `system.toml`, never in the query program.
