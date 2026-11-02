//! The system file (`systems/<name>/system.toml`): what the runner needs to know about a
//! database system besides its scripts (`install`, `start`, `stop`) and its query program. See
//! docs/RUNNER.md.

use std::collections::BTreeMap;
use std::path::{Path, PathBuf};

use anyhow::{Context, Result, bail};
use serde::Deserialize;

use crate::config::Keys;
use crate::dialect::DialectSpec;

/// How the system reads array columns from Parquet.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum Arrays {
    /// Parquet lists
    Native,
    /// PostgreSQL array literals in text (`{"a","b"}`): the tables with array columns come from
    /// a converted copy
    Text,
}

#[derive(Debug, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Load {
    /// The statement that loads the Parquet file `{file}` into `{table}`. A load runs it for every
    /// table, with the table's file of the load's period.
    pub statement: String,
}

#[derive(Debug, Default, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Ddl {
    /// text after the closing parenthesis of every CREATE TABLE
    #[serde(default)]
    pub suffix: String,
    /// the same, when the tables have no primary keys (default: `suffix`)
    pub suffix_without_keys: Option<String>,
}

/// A container started next to the system's own (which runs the scripts), in the same pod.
#[derive(Debug, Clone, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Container {
    pub name: String,
    pub image: String,
    /// overrides the image's command
    #[serde(default)]
    pub command: Vec<String>,
    #[serde(default)]
    pub env: BTreeMap<String, String>,
    /// resource limits, e.g. "nofile=524288:524288"
    #[serde(default)]
    pub ulimits: Vec<String>,
    /// the user to run as instead of the image's, e.g. "root" (in the container: podman runs
    /// without root, so this is the user who runs the benchmark)
    pub user: Option<String>,
    /// mount the data writable in this container (default: read-only), for a system that
    /// only opens files for writing; the runner then checks afterwards that no file changed
    #[serde(default)]
    pub data_writable: bool,
}

#[derive(Debug, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct System {
    pub name: String,
    /// the system of the benchmark this one is based on (docs/RUNNER.md), e.g. "postgres" for an extension of
    /// PostgreSQL: the website shows it under its base, and only when asked to
    pub based_on: Option<String>,
    #[serde(default = "native")]
    pub arrays: Arrays,
    /// the `keys` settings the system can run (default: all)
    #[serde(default = "all_keys")]
    pub keys: Vec<Keys>,
    pub load: Load,
    /// the system's version, as text, kept with the results (set by hand, without the name: e.g. "1.5.6", or "1.1.0 (PostgreSQL 18.1)")
    pub version: String,
    #[serde(default)]
    pub ddl: Ddl,
    #[serde(default)]
    pub dialect: DialectSpec,
    #[serde(default, rename = "container")]
    pub containers: Vec<Container>,
    /// the scale factor from which on the system is disabled (default: none); a configuration at or
    /// above it is skipped, and the website shows `scale_limit_message` instead
    pub scale_limit: Option<f64>,
    /// why the system does not run from `scale_limit` on, as the website shows it
    pub scale_limit_message: Option<String>,
    #[serde(skip)]
    pub dir: PathBuf,
}

fn native() -> Arrays {
    Arrays::Native
}

fn all_keys() -> Vec<Keys> {
    vec![Keys::None, Keys::Primary]
}

impl System {
    pub fn read(dir: &Path) -> Result<System> {
        let file = dir.join("system.toml");
        let text = std::fs::read_to_string(&file).with_context(|| format!("reading {}", file.display()))?;
        let mut s: System = toml::from_str(&text).with_context(|| format!("system file {}", file.display()))?;
        s.dir = dir.to_path_buf();
        if !s.load.statement.contains("{file}") {
            bail!("{}: the load statement needs {{file}}", file.display());
        }
        if s.scale_limit.is_some() != s.scale_limit_message.is_some() {
            bail!("{}: scale_limit and scale_limit_message go together", file.display());
        }
        if let Some(b) = &s.based_on {
            let base = dir.with_file_name(b).join("system.toml");
            if b.contains('/') || !base.is_file() {
                bail!("{}: based_on: no system {b}", file.display());
            }
            // one level: the website shows a system under its base, and the base among the others
            let base: toml::Table = toml::from_str(&std::fs::read_to_string(&base)?).with_context(|| format!("system file {}", base.display()))?;
            if base.contains_key("based_on") {
                bail!("{}: based_on: {b} is itself based on another system", file.display());
            }
        }
        if !dir.join("start").is_file() {
            bail!("{}: no start script (it starts the query program)", dir.display());
        }
        Ok(s)
    }

    pub fn ddl_suffix(&self, keys: Keys) -> &str {
        match (keys, &self.ddl.suffix_without_keys) {
            (Keys::None, Some(s)) => s,
            _ => &self.ddl.suffix,
        }
    }
}

/// Replace `{name}` placeholders from `vars`; unknown names are an error. `{name%45}` is 45
/// percent of a number (e.g. a share of the memory).
pub fn subst(s: &str, vars: &BTreeMap<String, String>) -> Result<String> {
    let mut out = String::with_capacity(s.len());
    let mut rest = s;
    while let Some(i) = rest.find('{') {
        out.push_str(&rest[..i]);
        let after = &rest[i + 1..];
        let Some(j) = after.find('}') else { bail!("unclosed placeholder in {s:?}") };
        let name = &after[..j];
        let (name, percent) = match name.split_once('%') {
            Some((n, p)) => (n, Some(p.parse::<u64>().ok().with_context(|| format!("bad percentage in {s:?}"))?)),
            None => (name, None),
        };
        match (vars.get(name), percent) {
            (Some(v), None) => out.push_str(v),
            (Some(v), Some(p)) => out.push_str(&(v.parse::<u64>().ok().with_context(|| format!("{{{name}}} is not a number in {s:?}"))? * p / 100).to_string()),
            (None, _) => bail!("unknown placeholder {{{name}}} in {s:?} (known: {})", vars.keys().cloned().collect::<Vec<_>>().join(", ")),
        }
        rest = &after[j + 1..];
    }
    out.push_str(rest);
    Ok(out)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn placeholders() {
        let v: BTreeMap<String, String> = [("table", "t"), ("threads", "4")].iter().map(|(a, b)| (a.to_string(), b.to_string())).collect();
        assert_eq!(subst("COPY {table} -t {threads}", &v).unwrap(), "COPY t -t 4");
        assert_eq!(subst("{threads%50}G", &v).unwrap(), "2G");
        assert!(subst("{table%50}", &v).is_err());
        assert!(subst("{nope}", &v).is_err());
        assert!(subst("{table", &v).is_err());
    }

    /// Every system directory in the repository parses (a directory with a system.toml: dbo/ is
    /// the query programs' library).
    #[test]
    fn systems_parse() {
        let dir = Path::new(env!("CARGO_MANIFEST_DIR")).join("../systems");
        let mut n = 0;
        for e in std::fs::read_dir(&dir).unwrap() {
            let p = e.unwrap().path();
            if p.join("system.toml").is_file() {
                let s = System::read(&p).unwrap();
                crate::dialect::Dialect::new(&s.dialect).unwrap();
                crate::ddl::Types::new(&s.dialect.types).unwrap();
                assert_eq!(Some(s.name.as_str()), p.file_name().and_then(|n| n.to_str()));
                n += 1;
            }
        }
        assert!(n > 0);
    }
}
