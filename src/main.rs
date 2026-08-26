//! Completes an abbreviated duckdb statement, whole: supplies the SELECT it was
//! typed without, names the table a mutation writes to, and points every SELECT
//! that names no source at the buffer.
//!
//! From the parse, and only from the parse. sqruff reads the statement and says
//! where the FROM clauses belong. Because it parses leniently and keeps every
//! byte it read, the answer is an *offset*: the FROM is spliced in and nothing
//! else is touched, so nothing gets reformatted, and a dialect only half known
//! cannot quietly rewrite what it did not understand. Every repair is checked
//! against the tree before it is taken.
//!
//! A statement sqruff cannot read in full is turned down rather than guessed
//! at. Its duckdb dialect stops short of GROUP BY without a FROM, QUALIFY,
//! TABLESAMPLE and FROM-first syntax; those come back unparsable, and the
//! caller has nothing to fall back on.
//!
//! Comments are dropped up front: anything appended to a statement ending in
//! one would land inside it, and duckdb has no use for them regardless.
//!
//! Reads {"statement": ..., "table": ...} on stdin and writes one of:
//!
//!     {"ok": true, "sql": ..., "strategy": "parsed", ...}
//!     {"ok": false, "error": ...}
//!
//! What the completed statement *does* with the buffer is not reported: it
//! opens with the keyword that says so, every repair having already been made,
//! so the caller can read it off the first word without parsing anything.

use std::io::Read;
use std::ops::Range;

use serde::{Deserialize, Serialize};
use sqruff_lib::core::config::FluffConfig;
use sqruff_lib::core::linter::core::Linter;
use sqruff_lib_core::dialects::syntax::{SyntaxKind, SyntaxSet};
use sqruff_lib_core::parser::segments::{ErasedSegment, Tables};

/// Every descendant of `segment` of this kind, `segment` itself included.
fn crawl(segment: &ErasedSegment, kind: SyntaxKind) -> Vec<ErasedSegment> {
    segment.recursive_crawl(&SyntaxSet::single(kind), true, &SyntaxSet::EMPTY, true)
}

/// The child of `segment` of this kind, if it has one.
fn child(segment: &ErasedSegment, kind: SyntaxKind) -> Option<ErasedSegment> {
    segment.child(&SyntaxSet::single(kind))
}

/// Where `segment` sits in the text it was read from.
fn span(segment: &ErasedSegment) -> Option<Range<usize>> {
    segment
        .get_position_marker()
        .map(|marker| marker.source_slice.clone())
}

/// The statement in tokens, strings and comments each held whole.
fn lex(config: &FluffConfig, sql: &str) -> Vec<ErasedSegment> {
    let tables = Tables::default();
    let (segments, _errors) = config.get_dialect().lexer().lex(&tables, sql);
    segments
}

/// Everything but the comments.
///
/// A comment cannot survive being completed -- a FROM appended to a statement
/// ending in `-- note` lands inside the note -- and it means nothing to duckdb
/// either, so it goes before any of this starts. Only real comments go: the
/// lexer hands a string literal back whole, so `'-- not a comment'` is left
/// exactly where it is.
fn strip_comments(config: &FluffConfig, sql: &str) -> String {
    let mut stripped = sql.to_string();

    // Back to front, so the ranges still ahead stay valid.
    for segment in lex(config, sql).iter().rev() {
        if segment.is_comment() {
            if let Some(at) = span(segment) {
                stripped.replace_range(at, "");
            }
        }
    }

    stripped
}

/// True when every SELECT in `tree` actually selects something.
///
/// This is the check that makes supplying the SELECT safe. sqruff parses
/// `select where a > 1` quite happily -- an empty projection is valid grammar --
/// and duckdb then rejects `select from this where a > 1`. A tree that parses is
/// therefore not yet a tree that can be fixed; one with nothing between SELECT
/// and the next clause has to be turned down so the next candidate is tried.
fn projections_are_present(tree: &ErasedSegment) -> bool {
    crawl(tree, SyntaxKind::SelectStatement)
        .iter()
        .all(|select| {
            let clause = child(select, SyntaxKind::SelectClause);
            clause.is_some_and(|clause| child(&clause, SyntaxKind::SelectClauseElement).is_some())
        })
}

/// True when sqruff could not read part of the statement. Its guess about the
/// rest is not worth splicing into.
fn has_unparsable(tree: &ErasedSegment) -> bool {
    !crawl(tree, SyntaxKind::Unparsable).is_empty()
}

/// What may be put in front of a statement typed without a SELECT. Nothing
/// first, since a statement that already reads is not to be touched; then the
/// bare list form, then the bare clause form.
const PREFIXES: [&str; 3] = ["", "select ", "select * "];

/// The tree sqruff makes of `sql`, however much of it it could read.
fn parse(linter: &Linter, sql: &str) -> Option<ErasedSegment> {
    linter
        .parse_string(&Tables::default(), sql, None)
        .ok()?
        .tree
}

/// Whether `tree` is one to finish a statement from: it accounts for all of
/// `sql`, was read in full, and every SELECT in it actually selects something.
fn usable(tree: &ErasedSegment, sql: &str) -> bool {
    covers(tree, sql)
        && !has_unparsable(tree) // DESCRIBE, UPDATE, DELETE already stops here
        && projections_are_present(tree)
        && sources_are_named(tree) // SELECT can be SELECT 1, but this plugin is for querying a csv
                                   // so by default the assumption is SELECT without from-ing this
                                   // csv file is dumb
}

/// True when every SELECT in `tree` says what it reads from.
///
/// A SELECT without a FROM parses perfectly well -- it is only unfinished, not
/// unreadable -- so nothing else here would notice. Saying so is what puts the
/// missing FROM through the same mend-and-parse-again loop as everything else,
/// rather than being spliced in afterwards and never checked.
fn sources_are_named(tree: &ErasedSegment) -> bool {
    crawl(tree, SyntaxKind::SelectStatement)
        .iter()
        .all(|select| child(select, SyntaxKind::FromClause).is_some())
}

/// Whether the tree reaches the end of what it was given.
///
/// sqruff stops at the first thing its lexer cannot take -- a non-ASCII letter
/// in an unquoted identifier, say -- and leaves the rest out of the tree
/// altogether rather than marking it unreadable. Such a tree looks perfectly
/// healthy: no unparsable node, a select clause, a projection. Checking that it
/// ends where the statement ends is what tells the difference, and without it
/// an offset taken from the tree would be spliced into text the parse never
/// saw.
fn covers(tree: &ErasedSegment, sql: &str) -> bool {
    span(tree).is_some_and(|at| at.end >= sql.len())
}

/// Somewhere the parse stopped following, and what is missing there.
struct Repair {
    at: usize,
    text: String,
}

impl Repair {
    /// Splices the missing text into `sql`, keeping it apart from the words
    /// either side of it -- and only from words. An opening bracket is already
    /// a separator, and punctuation on the far side needs none, so neither
    /// gains a space it did not have.
    fn apply(&self, sql: &mut String) {
        let (before, after) = (&sql[..self.at], &sql[self.at..]);

        let mut text = String::with_capacity(self.text.len() + 2);
        // Anything but a separator on the left wants one; only a word on the
        // right does, since punctuation there needs no room.
        if !before.is_empty() && !before.ends_with([' ', '\t', '\n', '(']) {
            text.push(' ');
        }
        text.push_str(&self.text);
        if after.starts_with(|c: char| c.is_alphanumeric() || "_\"'".contains(c)) {
            text.push(' ');
        }

        sql.insert_str(self.at, &text);
    }
}

/// The relation a statement never named, read off the statement the parser
/// could not make anything of.
///
/// `update set x = 1` names no table, and sqruff says so plainly: the whole
/// statement comes back as one unreadable node rather than `set` being taken
/// for a table. Which relation is missing, and where it goes, then follows from
/// the opening keyword and the position the parse gives for it.
///
/// The keyword has to be the first thing in the unreadable stretch, exactly as
/// it has to be the first thing in the statement for a SELECT to be withheld
/// from it. A word reached only by opening a bracket is a column name, not a
/// statement: `(delete where y > 1)` is a subquery written without its SELECT,
/// and reading its `delete` as a statement turns a projection into a DELETE.
fn missing_relation(unreadable: &ErasedSegment, table: &str) -> Option<Repair> {
    let mut code = unreadable
        .segments()
        .iter()
        .filter(|segment| segment.is_code());

    let head = code
        .next()
        .filter(|first| first.is_type(SyntaxKind::Word))?;
    let next = code
        .find(|segment| segment.is_type(SyntaxKind::Word))
        .map(|word| word.raw().to_lowercase());

    // Each arm names the relation only when the statement plainly has none: an
    // UPDATE going straight to its SET, a DELETE or INSERT without its
    // preposition, a bare DESCRIBE or SUMMARIZE. A statement that already says
    // what it acts on is unreadable for some other reason, and wedging a second
    // relation into it mends nothing.
    let text = match head.raw().to_lowercase().as_str() {
        "update" if next.as_deref() == Some("set") => table.to_string(),
        "delete" if next.as_deref() != Some("from") => format!("from {table}"),
        "insert" if next.as_deref() != Some("into") => format!("into {table}"),
        // DESCRIBE and SUMMARIZE take the relation as their whole operand.
        "describe" | "summarize" if next.is_none() => table.to_string(),
        _ => return None,
    };

    Some(Repair {
        at: span(head)?.end,
        text,
    })
}

/// The first place a statement needs mending, if it needs mending anywhere.
///
/// Three shapes, each of which the parse points straight at:
///
/// A **select clause holding something unreadable** is a missing FROM. GROUP BY
/// and HAVING do not end a select list the way WHERE and ORDER BY do, so with
/// no FROM to end it the list runs on until it reaches a word it cannot take.
/// That word starts exactly where the FROM belongs.
///
/// A **bracket holding something unreadable** is a subquery written without its
/// SELECT: `(b where c > 1)` parses as far as `b` and no further.
///
/// A **whole statement the parser could not read**, opening with a keyword that
/// acts on a relation, never named the relation: `update set x = 1`, `describe`.
///
/// Only the first site is returned. Everything past an unreadable stretch is
/// held as raw words rather than parsed, so a second site inside one is not
/// visible until the first has been mended and the statement read again.
fn repair_sites(tree: &ErasedSegment, table: &str) -> Vec<Repair> {
    // A statement that did not parse at all sits unreadable at the root.
    let unnamed = child(tree, SyntaxKind::Unparsable)
        .and_then(|statement| missing_relation(&statement, table));

    let selects = crawl(tree, SyntaxKind::SelectStatement);
    let brackets = crawl(tree, SyntaxKind::Bracketed);

    // A SELECT that named no source. The FROM goes where the select list
    // actually ended: at the word the list could not take, if it ran on past
    // the clause that should have stopped it, and at the end of the clause
    // otherwise -- a runaway clause ends where the statement does, which is not
    // where a FROM belongs.
    let unsourced = selects
        .iter()
        .filter(|select| child(select, SyntaxKind::FromClause).is_none())
        .filter_map(|select| child(select, SyntaxKind::SelectClause))
        .filter_map(|clause| unparsable_child(&clause).or_else(|| span(&clause).map(|at| at.end)))
        .map(|at| Repair {
            at,
            text: format!("from {table}"),
        });

    let unselected = brackets
        .iter()
        .filter(|bracket| unparsable_child(bracket).is_some())
        .filter_map(|bracket| child(bracket, SyntaxKind::StartBracket))
        .filter_map(|opened| span(&opened).map(|at| at.end))
        .map(|at| Repair {
            at,
            text: "select".to_string(),
        });

    let mut sites: Vec<Repair> = unnamed
        .into_iter()
        .chain(unsourced)
        .chain(unselected)
        .collect();

    // Highest offset first, so each mend leaves the ones still to come where
    // the parse found them. Tree order will not do: a nested SELECT is crawled
    // after the one holding it but sits earlier in the text.
    sites.sort_by_key(|site| std::cmp::Reverse(site.at));
    sites
}

/// Where the first unreadable child of `segment` starts.
fn unparsable_child(segment: &ErasedSegment) -> Option<usize> {
    child(segment, SyntaxKind::Unparsable)
        .and_then(|unreadable| span(&unreadable))
        .map(|at| at.start)
}

/// How many times a statement may be mended before we call it unreadable. Each
/// round fixes one level, and a statement nested deeper than this is not one
/// anybody typed at a `:Duck` prompt.
const MAX_REPAIRS: usize = 8;

/// The first prefix under which the statement reads, mending it as far as the
/// parse will show the way.
///
/// Nothing about the statement is decided before it is parsed. One that already
/// reads takes the empty prefix and is never touched; one that does not is
/// offered a SELECT, and what comes of that must parse like anything else. A
/// statement this dialect has no grammar for -- PIVOT, TABLE -- is refused, or
/// completes into something duckdb then names the offending keyword in.
fn completed(
    linter: &Linter,
    statement: &str,
    table: &str,
) -> Option<(&'static str, String, usize)> {
    for &prefix in PREFIXES.iter() {
        let mut candidate = format!("{prefix}{statement}");

        for repairs in 0..=MAX_REPAIRS {
            let Some(tree) = parse(linter, &candidate) else {
                break;
            };
            if usable(&tree, &candidate) {
                return Some((prefix, candidate, repairs));
            }
            if repairs == MAX_REPAIRS {
                break; // one more mend could not be checked anyway
            }
            let sites = repair_sites(&tree, table);
            if sites.is_empty() {
                break; // unfinished for a reason no insertion will mend
            }
            for site in &sites {
                site.apply(&mut candidate);
            }
        }
    }

    None
}

/// What was asked for: a statement, and the name the buffer answers to.
///
/// Both are optional twice over: absent, and present as null. A caller whose
/// JSON encoder writes an unset field out as `null` rather than leaving it off
/// means the same thing by it, and is answered the same way.
#[derive(Deserialize)]
struct Request {
    #[serde(default)]
    statement: Option<String>,
    #[serde(default)]
    table: Option<String>,
}

impl Request {
    fn statement(&self) -> &str {
        self.statement.as_deref().unwrap_or("")
    }

    fn table(&self) -> &str {
        self.table.as_deref().unwrap_or("this")
    }
}

/// How a statement came to read: as typed, or after being mended.
#[derive(Serialize)]
#[serde(rename_all = "lowercase")]
enum Strategy {
    Parsed,
    Repaired,
}

/// What is written back, in the one shape the caller may rely on.
#[derive(Serialize)]
#[serde(untagged)]
enum Answer {
    Completed {
        /// Always true. The caller branches on it before reading anything else.
        ok: bool,
        sql: String,
        strategy: Strategy,
        repairs: usize,
        /// The SELECT put in front, if one was needed.
        supplied: Option<&'static str>,
    },
    Refused {
        /// Always false.
        ok: bool,
        error: String,
    },
}

impl Answer {
    fn refused(why: impl Into<String>) -> Self {
        Answer::Refused {
            ok: false,
            error: why.into(),
        }
    }
}

fn complete(statement: &str, table: &str) -> Answer {
    let config = FluffConfig::from_source("[sqruff]\ndialect = duckdb\n", None);
    let linter = match Linter::new(config, None, None, false) {
        Ok(linter) => linter,
        Err(why) => return Answer::refused(why),
    };
    // Borrowed back rather than kept alongside: cloning it copies the whole
    // duckdb grammar the linter has just been handed.
    let config = linter.config();

    let stripped = strip_comments(config, statement);
    let trimmed = stripped.trim();
    let statement = if trimmed.is_empty() { "*" } else { trimmed };

    let Some((prefix, candidate, repairs)) = completed(&linter, statement, table) else {
        return Answer::refused("sqruff could not read the whole statement");
    };

    Answer::Completed {
        ok: true,
        sql: candidate,
        strategy: if repairs == 0 {
            Strategy::Parsed
        } else {
            Strategy::Repaired
        },
        repairs,
        supplied: (!prefix.is_empty()).then_some(prefix),
    }
}

fn main() {
    let mut input = String::new();
    let answer = if std::io::stdin().read_to_string(&mut input).is_err() {
        Answer::refused("could not read stdin")
    } else {
        match serde_json::from_str::<Request>(&input) {
            Ok(request) => complete(request.statement(), request.table()),
            Err(why) => Answer::refused(why.to_string()),
        }
    };

    println!("{}", serde_json::to_string(&answer).unwrap());
}
