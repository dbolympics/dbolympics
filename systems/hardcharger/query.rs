//! Hardcharger's own CLI executes every statement over Warp SQL, in one process and
//! session for the whole run. Local .once/.echo commands frame its CSV output; they
//! do not send SQL or start a process. HTTP is used only for cancellation.

use std::io::{BufRead, BufReader, Write};
use std::os::unix::net::UnixStream;
use std::process::{Child, ChildStdin, Command, Stdio};

use serde_json::json;

const API: &str = "http://127.0.0.1:31337/warp/v1";
const CSV: &str = "/run/dbo/hardcharger.csv";
const BARRIER: &str = "echo: off\n";

struct System {
    child: Child,
    input: ChildStdin,
    output: BufReader<UnixStream>,
}
struct Cancel {
    http: ureq::Agent,
    bearer: String,
    url: String,
}

impl System {
    fn connect() -> (System, Cancel) {
        let http: ureq::Agent = ureq::Agent::config_builder().build().into();
        // Also waits for the server. No benchmark SQL uses this control channel.
        let token: serde_json::Value = dbo::retry(|| {
            http.post(&format!("{API}/auth/token"))
                .send_json(
                    json!({"grant_type": "password", "username": "bench", "password": "bench"}),
                )
                .map_err(|e| e.to_string())?
                .body_mut()
                .read_json()
                .map_err(|e| e.to_string())
        });
        let bearer = format!(
            "Bearer {}",
            token["access_token"].as_str().expect("access token")
        );

        // Merge diagnostics into one ordered stream, separate from the result CSV.
        let (output, writer) = UnixStream::pair().unwrap();
        let mut child = Command::new("hardcharger")
            .args([
                "--host",
                "127.0.0.1",
                "--no-tls",
                "--username",
                "bench",
                "--quiet",
                "--csv",
                "--no-header",
                "--null",
                "",
                "--no-init",
                "--result-partitions",
                "1",
            ])
            .env("HARDCHARGER_PASSWORD", "bench")
            .env("NO_COLOR", "1")
            .stdin(Stdio::piped())
            .stdout(Stdio::from(std::os::fd::OwnedFd::from(
                writer.try_clone().unwrap(),
            )))
            .stderr(Stdio::from(std::os::fd::OwnedFd::from(writer)))
            .spawn()
            .expect("start hardcharger CLI");
        let input = child.stdin.take().unwrap();
        let mut system = System {
            child,
            input,
            output: BufReader::new(output),
        };
        // The CLI's actual session, rather than another SQL connection for cancellation.
        let session = system
            .run(
                "SELECT session_id FROM hardcharger_active_connections() WHERE is_current",
                0,
            )
            .expect("identify CLI session");
        let session = String::from_utf8(session).unwrap();
        let session = session.trim();
        assert!(
            session.starts_with("s_")
                && session
                    .bytes()
                    .all(|b| b.is_ascii_alphanumeric() || b == b'_'),
            "session id"
        );
        let cancel = Cancel {
            http,
            bearer,
            url: format!("{API}/sessions/{session}/cancel"),
        };
        (system, cancel)
    }

    fn run(&mut self, sql: &str, _timeout: u32) -> Result<Vec<u8>, String> {
        // .once closes (and flushes) the file after this statement, even on an error.
        // A separate terminator also handles SQL ending in a line comment. The CLI
        // parses statement terminators; the benchmark SQL itself is passed unchanged.
        write!(self.input, ".once {CSV}\n{sql}\n;\n.echo\n")
            .and_then(|_| self.input.flush())
            .expect("write to hardcharger CLI");
        let mut errors = String::new();
        loop {
            let mut line = String::new();
            assert!(
                self.output
                    .read_line(&mut line)
                    .expect("read hardcharger CLI")
                    > 0,
                "hardcharger CLI exited: {errors}"
            );
            if line == BARRIER {
                break;
            }
            errors.push_str(&line);
        }
        if !errors.is_empty() {
            return Err(errors.trim().to_owned());
        }
        Ok(std::fs::read(CSV).expect("read CLI result"))
    }
}

impl Drop for System {
    fn drop(&mut self) {
        let _ = self.child.kill();
        let _ = self.child.wait();
    }
}

impl Cancel {
    fn cancel(&self) {
        // Synchronous acknowledgement: only work already running in this session
        // is cancelled. No delayed SIGINT can hit the next statement or stop the CLI
        // while it formats CSV. dbo joins this call before accepting the next request.
        if let Err(e) = self
            .http
            .post(&self.url)
            .header("Authorization", &self.bearer)
            .send_empty()
            .and_then(|mut r| r.body_mut().read_to_vec().map(|_| ()))
        {
            eprintln!("Hardcharger cancel failed: {e}");
        }
    }
}

fn main() {
    let (mut system, cancel) = System::connect();
    dbo::serve(|sql, timeout| system.run(sql, timeout), || cancel.cancel());
}
