//! Render a canonical benchmark query for one system.
//!
//! A canonical query (`workload/queries/qNNN.sql`) is SQL with placeholders where systems need
//! different text, written `{{name(arg, arg)}}`. Arguments are SQL expressions separated by
//! top-level commas. Each placeholder is a customization point with a standard-SQL default; a
//! system overrides points with text templates in the `[dialect]` section of its system file.
//! Templates are text, never code.

use std::collections::BTreeMap;

use anyhow::{Context, Result, bail};
use serde::Deserialize;

/// A customization point: placeholder name, parameter names and the default template.
struct Point {
    name: &'static str,
    params: &'static [&'static str],
    default: &'static str,
}

/// `{window}` is the window specification without its parentheses.
const POINTS: &[Point] = &[
    Point { name: "date_diff_days", params: &["a", "b"], default: "(CAST({b} AS DATE) - CAST({a} AS DATE))" },
    Point { name: "year_month", params: &["x"], default: "to_char({x}, 'YYYY-MM')" },
    // the first n rows (the standard's clause)
    Point { name: "fetch_first", params: &["n"], default: "FETCH FIRST {n} ROWS ONLY" },
    // PostgreSQL's spelling; not in the SQL standard, which has no boolean OR aggregate most
    // systems implement
    Point { name: "bool_or", params: &["x"], default: "BOOL_OR({x})" },
    // the standard ordered-set aggregate (linear interpolation between the closest values)
    Point { name: "percentile_cont", params: &["p", "x"], default: "PERCENTILE_CONT({p}) WITHIN GROUP (ORDER BY {x})" },
    // the same, over the rows that meet a condition
    Point {
        name: "percentile_cont_filter",
        params: &["p", "x", "condition"],
        default: "PERCENTILE_CONT({p}) WITHIN GROUP (ORDER BY {x}) FILTER (WHERE {condition})",
    },
    // the values joined with a separator, in their own order
    Point { name: "string_agg_sorted", params: &["x", "sep"], default: "STRING_AGG({x}, {sep} ORDER BY {x})" },
    Point { name: "string_agg_distinct_sorted", params: &["x", "sep"], default: "STRING_AGG(DISTINCT {x}, {sep} ORDER BY {x})" },
    // the number of distinct (a, b) pairs, counted as a row value
    Point { name: "count_distinct_pair", params: &["a", "b"], default: "COUNT(DISTINCT ({a}, {b}))" },
    // whether an array column contains x: the standard's membership test (`= ANY(array)` is
    // PostgreSQL's), with the same result for NULLs
    Point {
        name: "equals_any",
        params: &["x", "arr"],
        default: "{x} IN (SELECT dbo_unnest.dbo_element FROM UNNEST({arr}) AS dbo_unnest(dbo_element))",
    },
    // a timestamp plus n minutes (the standard's interval literal; MySQL, T-SQL and SQLite have no
    // interval type)
    Point { name: "add_minutes", params: &["ts", "n"], default: "{ts} + {n} * INTERVAL '1 minute'" },
    // whole days from a to b, two timestamps: the day field of their difference (the standard
    // needs an interval qualifier no reference dialect supports)
    Point { name: "whole_days_between", params: &["a", "b"], default: "EXTRACT(DAY FROM {b} - {a})" },
    // the midpoint of two timestamps (the same)
    Point { name: "timestamp_midpoint", params: &["a", "b"], default: "{a} + ({b} - {a}) * 0.5" },
    // the exact seconds from a to b (docs/NUMERICS.md)
    Point { name: "seconds_between", params: &["a", "b"], default: "CAST(EXTRACT(EPOCH FROM ({b} - {a})) AS NUMERIC(18,6))" },
    // COUNT(DISTINCT x) OVER window, standard SQL when the window has no ORDER BY or frame;
    // a system without DISTINCT window aggregates computes the distinct non-NULL values of x in
    // the partition from two dense ranks:
    // (DENSE_RANK() OVER ({window} ORDER BY {x} ASC NULLS FIRST) + DENSE_RANK() OVER ({window}
    //  ORDER BY {x} DESC NULLS LAST) - 1 - MAX(CASE WHEN {x} IS NULL THEN 1 ELSE 0 END) OVER ({window}))
    Point { name: "count_distinct_over", params: &["x", "window"], default: "COUNT(DISTINCT {x}) OVER ({window})" },
];

/// The customization points: name, parameters and default template, for documentation.
pub fn points() -> Vec<(&'static str, &'static [&'static str], &'static str)> {
    POINTS.iter().map(|p| (p.name, p.params, p.default)).collect()
}

fn signature(p: &Point) -> String {
    format!("{}({})", p.name, p.params.join(", "))
}

/// The `[dialect]` section of a system file.
#[derive(Debug, Default, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct DialectSpec {
    /// statements to run after every (re)start, before the queries
    #[serde(default)]
    pub settings: Vec<String>,
    /// templates keyed by signature, e.g. `"year_month(x)" = "strftime({x}, '%Y-%m')"`
    #[serde(default)]
    pub functions: BTreeMap<String, String>,
    /// type names for the schema, e.g. `json = "jsonb"` (see ddl.rs for the points)
    #[serde(default)]
    pub types: BTreeMap<String, String>,
}

pub struct Dialect {
    pub settings: Vec<String>,
    /// one template per point, in the order of POINTS
    templates: Vec<String>,
}

impl Dialect {
    pub fn new(spec: &DialectSpec) -> Result<Dialect> {
        let mut templates: Vec<String> = POINTS.iter().map(|p| p.default.to_string()).collect();
        for (sig, t) in &spec.functions {
            let norm: String = sig.chars().filter(|c| !c.is_whitespace()).collect();
            let i = POINTS
                .iter()
                .position(|p| signature(p).replace(' ', "") == norm)
                .with_context(|| {
                    let known: Vec<String> = POINTS.iter().map(signature).collect();
                    format!("unknown customization point {sig:?} (known: {})", known.join(", "))
                })?;
            check_template(t, POINTS[i].params).with_context(|| format!("template for {sig}"))?;
            templates[i] = t.clone();
        }
        Ok(Dialect { settings: spec.settings.clone(), templates })
    }

    /// Replace every placeholder (innermost first) with the dialect's text.
    pub fn render(&self, sql: &str) -> Result<String> {
        self.render_with(sql, false)
    }

    /// The same, with every replaced placeholder between comments that name it,
    /// `/*{name*/ ... /*}*/`, so that its text can be shown (the result is still valid SQL).
    pub fn render_marked(&self, sql: &str) -> Result<String> {
        self.render_with(sql, true)
    }

    fn render_with(&self, sql: &str, mark: bool) -> Result<String> {
        let mut sql = sql.to_string();
        while sql.contains("{{") {
            let toks = tokenize(&sql)?;
            let Some(close) = toks.iter().position(|t| t.kind == Kind::Placeholder && t.text == "}}") else {
                if toks.iter().any(|t| t.kind == Kind::Placeholder) {
                    bail!("'{{{{' without '}}}}'");
                }
                break; // only inside strings, identifiers or comments
            };
            let start = toks[..close]
                .iter()
                .rposition(|t| t.kind == Kind::Placeholder && t.text == "{{")
                .context("'}}' without '{{'")?;
            let body: Vec<&Tok> = toks[start + 1..close].iter().skip_while(|t| t.kind == Kind::Ws).collect();
            let name = body.first().context("empty placeholder")?.text;
            let mut lp = 1;
            while body.get(lp).is_some_and(|t| t.kind == Kind::Ws) {
                lp += 1;
            }
            if body.get(lp).is_none_or(|t| t.text != "(") {
                bail!("placeholder {name} without arguments");
            }
            let rp = match_paren(&body, lp)?;
            let args: Vec<String> = split_args(&body[lp + 1..rp]).iter().map(|a| text(a).trim().to_string()).collect();
            let i = POINTS
                .iter()
                .position(|p| p.name == name && p.params.len() == args.len())
                .with_context(|| format!("unknown placeholder {name} with {} arguments", args.len()))?;
            let mut out = fill(&self.templates[i], POINTS[i].params, &args);
            if mark {
                out = format!("/*{{{name}*/{out}/*}}*/");
            }
            let head: String = toks[..start].iter().map(|t| t.text).collect();
            let tail: String = toks[close + 1..].iter().map(|t| t.text).collect();
            sql = format!("{head}{out}{tail}");
        }
        Ok(sql)
    }
}

/// Substitute `{param}` in a template. A `window` argument loses its outer parentheses.
fn fill(template: &str, params: &[&str], args: &[String]) -> String {
    let mut out = String::with_capacity(template.len() + 64);
    let mut rest = template;
    while let Some(i) = rest.find('{') {
        out.push_str(&rest[..i]);
        let after = &rest[i + 1..];
        let hit = after.find('}').and_then(|j| params.iter().position(|p| *p == &after[..j]).map(|k| (j, k)));
        match hit {
            Some((j, k)) => {
                let a = args[k].as_str();
                if params[k] == "window" {
                    let a = a.trim();
                    out.push_str(a.strip_prefix('(').and_then(|s| s.strip_suffix(')')).unwrap_or(a).trim());
                } else {
                    out.push_str(a);
                }
                rest = &after[j + 1..];
            }
            None => {
                out.push('{');
                rest = after;
            }
        }
    }
    out.push_str(rest);
    out
}

/// Every `{name}` in a template must be a parameter of its point.
fn check_template(t: &str, params: &[&str]) -> Result<()> {
    let mut rest = t;
    while let Some(i) = rest.find('{') {
        let after = &rest[i + 1..];
        if let Some(j) = after.find('}') {
            let name = &after[..j];
            if !name.is_empty() && name.chars().all(|c| c.is_ascii_alphanumeric() || c == '_') && !params.contains(&name) {
                bail!("unknown parameter {{{name}}} (parameters: {})", params.join(", "));
            }
        }
        rest = after;
    }
    Ok(())
}

// --- tokenizer --------------------------------------------------------------------------

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Kind {
    Ws,
    Comment,
    Str,
    QIdent,
    Placeholder,
    Number,
    Ident,
    Op,
}

#[derive(Debug)]
pub struct Tok<'a> {
    pub kind: Kind,
    pub text: &'a str,
}

const OPS2: &[&str] = &["::", "->>", "->", "<=", ">=", "<>", "!=", "||"];
const OPS1: &str = "-+*/%<>=(),.;[]{}|^~!@#&:?";

/// Splits SQL into tokens; text that starts no token is an error.
pub fn tokenize(sql: &str) -> Result<Vec<Tok<'_>>> {
    let b = sql.as_bytes();
    let mut out = Vec::new();
    let mut pos = 0;
    while pos < b.len() {
        let c = b[pos];
        let rest = &sql[pos..];
        let (kind, len) = if c.is_ascii_whitespace() {
            (Kind::Ws, rest.bytes().take_while(|c| c.is_ascii_whitespace()).count())
        } else if rest.starts_with("--") {
            (Kind::Comment, rest.find('\n').unwrap_or(rest.len()))
        } else if rest.starts_with("/*") && let Some(e) = rest[2..].find("*/") {
            (Kind::Comment, e + 4)
        } else if c == b'\'' {
            (Kind::Str, quoted(rest, b'\'').with_context(|| format!("unterminated string at {pos}"))?)
        } else if c == b'"' {
            (Kind::QIdent, quoted(rest, b'"').with_context(|| format!("unterminated identifier at {pos}"))?)
        } else if rest.starts_with("{{") || rest.starts_with("}}") {
            (Kind::Placeholder, 2)
        } else if let Some(n) = number(rest) {
            (Kind::Number, n)
        } else if c.is_ascii_alphabetic() || c == b'_' {
            (Kind::Ident, 1 + rest[1..].bytes().take_while(|c| c.is_ascii_alphanumeric() || *c == b'_' || *c == b'$').count())
        } else if let Some(op) = OPS2.iter().find(|o| rest.starts_with(**o)) {
            (Kind::Op, op.len())
        } else if OPS1.as_bytes().contains(&c) {
            (Kind::Op, 1)
        } else {
            let snippet: String = rest.chars().take(30).collect();
            bail!("cannot tokenize at {pos}: {snippet:?}");
        };
        out.push(Tok { kind, text: &rest[..len] });
        pos += len;
    }
    Ok(out)
}

/// Length of a quoted token (doubled quotes escape), or None if unterminated.
fn quoted(s: &str, q: u8) -> Option<usize> {
    let b = s.as_bytes();
    let mut i = 1;
    while i < b.len() {
        if b[i] == q {
            if b.get(i + 1) == Some(&q) {
                i += 2;
                continue;
            }
            return Some(i + 1);
        }
        i += 1;
    }
    None
}

/// `\d+(\.\d*)?([eE][-+]?\d+)?` or `\.\d+([eE][-+]?\d+)?`
fn number(s: &str) -> Option<usize> {
    let b = s.as_bytes();
    let digits = |i: usize| b[i..].iter().take_while(|c| c.is_ascii_digit()).count();
    let mut i = digits(0);
    if i > 0 {
        if b.get(i) == Some(&b'.') {
            i += 1 + digits(i + 1);
        }
    } else if b.first() == Some(&b'.') && b.len() > 1 && b[1].is_ascii_digit() {
        i = 1 + digits(1);
    } else {
        return None;
    }
    if matches!(b.get(i), Some(b'e' | b'E')) {
        let mut j = i + 1;
        if matches!(b.get(j), Some(b'+' | b'-')) {
            j += 1;
        }
        let d = if j < b.len() { digits(j) } else { 0 };
        if d > 0 {
            i = j + d;
        }
    }
    Some(i)
}

fn text(toks: &[&Tok]) -> String {
    toks.iter().map(|t| t.text).collect()
}

fn match_paren(toks: &[&Tok], i: usize) -> Result<usize> {
    let mut depth = 0;
    for (j, t) in toks.iter().enumerate().skip(i) {
        if t.kind == Kind::Op && t.text == "(" {
            depth += 1;
        } else if t.kind == Kind::Op && t.text == ")" {
            depth -= 1;
            if depth == 0 {
                return Ok(j);
            }
        }
    }
    bail!("unbalanced parentheses")
}

/// Split tokens at top-level commas.
fn split_args<'t, 'a>(toks: &'t [&'t Tok<'a>]) -> Vec<Vec<&'t Tok<'a>>> {
    let mut args = vec![Vec::new()];
    let mut depth = 0i32;
    for t in toks {
        if t.kind == Kind::Op && (t.text == "(" || t.text == "[") {
            depth += 1;
        } else if t.kind == Kind::Op && (t.text == ")" || t.text == "]") {
            depth -= 1;
        }
        if depth == 0 && t.kind == Kind::Op && t.text == "," {
            args.push(Vec::new());
        } else {
            args.last_mut().unwrap().push(*t);
        }
    }
    args
}

#[cfg(test)]
mod tests {
    use super::*;

    fn dialect(functions: &[(&str, &str)]) -> Dialect {
        let spec = DialectSpec {
            settings: vec![],
            functions: functions.iter().map(|(k, v)| (k.to_string(), v.to_string())).collect(),
            types: BTreeMap::new(),
        };
        Dialect::new(&spec).unwrap()
    }

    #[test]
    fn defaults() {
        let d = dialect(&[]);
        assert_eq!(d.render("SELECT {{year_month(o.created_at)}} FROM o").unwrap(), "SELECT to_char(o.created_at, 'YYYY-MM') FROM o");
        assert_eq!(d.render("{{date_diff_days(a, b)}}").unwrap(), "(CAST(b AS DATE) - CAST(a AS DATE))");
    }

    #[test]
    fn overrides_and_nesting() {
        let d = dialect(&[("date_diff_days(a, b)", "dd({a}, {b})"), ("year_month (x)", "ym({x})")]);
        assert_eq!(d.render("{{date_diff_days({{year_month(t)}}, now())}}").unwrap(), "dd(ym(t), now())");
    }

    #[test]
    fn marked() {
        let d = dialect(&[("date_diff_days(a, b)", "dd({a}, {b})"), ("year_month (x)", "ym({x})")]);
        assert_eq!(
            d.render_marked("SELECT {{date_diff_days({{year_month(t)}}, now())}}").unwrap(),
            "SELECT /*{date_diff_days*/dd(/*{year_month*/ym(t)/*}*/, now())/*}*/"
        );
        // marking changes nothing but the comments
        let plain = d.render("SELECT {{date_diff_days({{year_month(t)}}, now())}}").unwrap();
        let marked = d.render_marked("SELECT {{date_diff_days({{year_month(t)}}, now())}}").unwrap();
        let strip = |s: &str| s.replace("/*{date_diff_days*/", "").replace("/*{year_month*/", "").replace("/*}*/", "");
        assert_eq!(strip(&marked), plain);
    }

    #[test]
    fn window_loses_parentheses() {
        let d = dialect(&[]);
        assert_eq!(d.render("{{count_distinct_over(a, (PARTITION BY b))}}").unwrap(), "COUNT(DISTINCT a) OVER (PARTITION BY b)");
        let d = dialect(&[("count_distinct_over(x, window)", "(DENSE_RANK() OVER ({window} ORDER BY {x} ASC NULLS FIRST))")]);
        let r = d.render("{{count_distinct_over(a, ( PARTITION BY b ))}}").unwrap();
        assert!(r.starts_with("(DENSE_RANK() OVER (PARTITION BY b ORDER BY a ASC NULLS FIRST)"), "{r}");
    }

    #[test]
    fn placeholders_in_strings_are_text() {
        let d = dialect(&[]);
        assert_eq!(d.render("SELECT '{{', {{year_month(x)}} -- }}").unwrap(), "SELECT '{{', to_char(x, 'YYYY-MM') -- }}");
    }

    #[test]
    fn errors() {
        let bad = |f: &[(&str, &str)]| Dialect::new(&DialectSpec { functions: f.iter().map(|(k, v)| (k.to_string(), v.to_string())).collect(), ..Default::default() });
        assert!(bad(&[("concat(a, b)", "{a} + {b}")]).is_err());
        assert!(bad(&[("year_month(x)", "f({y})")]).is_err());
        let d = dialect(&[]);
        assert!(d.render("{{nope(x)}}").is_err());
        assert!(d.render("{{year_month(x, y)}}").is_err());
        assert!(d.render("{{year_month}}").is_err());
    }

    #[test]
    fn tokens() {
        let k: Vec<Kind> = tokenize("a.b::int ->> 'x''y' \"q\" 1.5e3 .5 /* c */ -- d").unwrap().iter().filter(|t| t.kind != Kind::Ws).map(|t| t.kind).collect();
        use Kind::*;
        assert_eq!(k, vec![Ident, Op, Ident, Op, Ident, Op, Str, QIdent, Number, Number, Comment, Comment]);
        assert!(tokenize("SELECT é").is_err());
    }
}
