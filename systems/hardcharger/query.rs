//! Hardcharger through its ADBC driver (the release's C shared library, installed by GizmoData's ADBC
//! installer and loaded by name, through its driver manifest, by Apache Arrow's Rust driver manager):
//! one database and one connection for the whole run. Every statement is
//! a new ADBC statement on that connection; a result's Arrow batches are written as CSV by
//! Arrow's writer, as the DuckDB entry does. A timeout cancels the running statement through
//! ADBC's StatementCancel, from the timer thread.

use std::sync::Mutex;

use adbc_core::options::{AdbcVersion, OptionDatabase, OptionValue};
use adbc_core::{CancelHandle, Connection, Database, Driver, LOAD_FLAG_DEFAULT, Statement};
use adbc_driver_manager::{ManagedConnection, ManagedDriver};

/// The driver's name: its manifest (hardcharger.toml, in /etc/adbc/drivers) names the library and the entrypoint.
const DRIVER: &str = "hardcharger";
const URI: &str = "hardcharger://127.0.0.1:31337?tls=false";

struct System {
    conn: ManagedConnection,
    running: &'static Mutex<Option<Box<dyn CancelHandle>>>,
}
struct Cancel(&'static Mutex<Option<Box<dyn CancelHandle>>>);

impl System {
    fn connect() -> (System, Cancel) {
        let mut driver = ManagedDriver::load_from_name(DRIVER, None, AdbcVersion::V110, LOAD_FLAG_DEFAULT, None)
            .expect("loading the Hardcharger ADBC driver");
        // Also waits for the server to start.
        let conn = dbo::retry(|| {
            let opts = [
                (OptionDatabase::Uri, OptionValue::String(URI.into())),
                (OptionDatabase::Username, OptionValue::String("bench".into())),
                (OptionDatabase::Password, OptionValue::String("bench".into())),
                // One result stream, as the CLI entry requests (--result-partitions 1).
                (
                    OptionDatabase::Other("hardcharger.query.result_partitions".into()),
                    OptionValue::String("1".into()),
                ),
            ];
            let db = driver.new_database_with_opts(opts).map_err(|e| e.to_string())?;
            let mut conn = db.new_connection().map_err(|e| e.to_string())?;
            // The connection opens its session lazily: make it now.
            run_on(&mut conn, "SELECT 1", None).map(|_| conn)
        });
        let running: &'static Mutex<Option<Box<dyn CancelHandle>>> = Box::leak(Box::new(Mutex::new(None)));
        (System { conn, running }, Cancel(running))
    }

    fn run(&mut self, sql: &str, _timeout: u32) -> Result<Vec<u8>, String> {
        run_on(&mut self.conn, sql, Some(self.running))
    }
}

fn run_on(conn: &mut ManagedConnection, sql: &str, running: Option<&Mutex<Option<Box<dyn CancelHandle>>>>) -> Result<Vec<u8>, String> {
    let e = |e: adbc_core::error::Error| e.message;
    let mut stmt = conn.new_statement().map_err(e)?;
    stmt.set_sql_query(sql).map_err(e)?;
    if let Some(r) = running {
        *r.lock().unwrap() = Some(stmt.get_cancel_handle());
    }
    let result = (|| {
        let reader = stmt.execute().map_err(e)?;
        let mut out = Vec::new();
        let mut w = arrow_csv::WriterBuilder::new().with_header(false).build(&mut out);
        for b in reader {
            w.write(&b.map_err(|e| e.to_string())?).map_err(|e| e.to_string())?;
        }
        drop(w);
        Ok(out)
    })();
    if let Some(r) = running {
        *r.lock().unwrap() = None;
    }
    result
}

impl Cancel {
    fn cancel(&self) {
        // Under the lock, so the statement stays alive while it is cancelled; dbo joins this
        // call before it answers, and so before the next statement starts.
        if let Some(h) = self.0.lock().unwrap().as_ref() {
            if let Err(e) = h.try_cancel() {
                eprintln!("Hardcharger ADBC cancel failed: {}", e.message);
            }
        }
    }
}

fn main() {
    let (mut system, cancel) = System::connect();
    dbo::serve(|sql, timeout| system.run(sql, timeout), || cancel.cancel());
}
