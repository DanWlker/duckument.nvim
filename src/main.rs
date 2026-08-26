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

/// Whether a word opens a query on its own, and so must never be offered a
/// SELECT in front of it: a keyword this dialect has no grammar for reads
/// perfectly well as a column name, and `describe` would quietly become
/// `select describe`.
fn opens_a_query(word: &str) -> bool {
    matches!(
        word,
        "select"
            | "with"
            | "from"
            | "describe"
            | "summarize"
            | "pivot"
            | "unpivot"
            | "table"
            | "values"
    )
}

/// Whether a word starts a statement that writes rather than reads.
fn mutates(word: &str) -> bool {
    matches!(word, "update" | "delete" | "insert")
}

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

/// What the statement opens with, lowercased, or "" if it opens with nothing.
///
/// The only thing read from the text rather than the parse, and only because it
/// decides what may be *put in front of* the statement before there is a parse
/// to read. Strings and comments never answer -- the lexer hands those back
/// whole, so a keyword written inside one is not a keyword here either. Nor
/// does anything inside brackets: `(select max(amt)) as peak` opens a select
/// *list*, not a query, and refusing it a prefix leaves it unreadable.
fn opening_word(config: &FluffConfig, sql: &str) -> String {
    let mut depth = 0usize;

    for segment in lex(config, sql) {
        match segment.get_type() {
            SyntaxKind::StartBracket => depth += 1,
            SyntaxKind::EndBracket => depth = depth.saturating_sub(1),
            SyntaxKind::Word if depth == 0 => return segment.raw().to_lowercase(),
            _ => {}
        }
    }

    String::new()
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

/// Where a missing FROM belongs in one SELECT: just past its select clause.
fn missing_froms(tree: &ErasedSegment) -> Vec<usize> {
    crawl(tree, SyntaxKind::SelectStatement)
        .iter()
        .filter(|select| child(select, SyntaxKind::FromClause).is_none())
        // The FROM follows the select clause, so the end of that clause is the
        // one position that is right whatever else the statement holds.
        .filter_map(|select| child(select, SyntaxKind::SelectClause))
        .filter_map(|clause| span(&clause).map(|at| at.end))
        .collect()
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
    covers(tree, sql) && !has_unparsable(tree) && projections_are_present(tree)
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
    /// Whether the text wants a space in front of it. A SELECT going straight
    /// after a `(` does not; a FROM landing against the word that ended the
    /// select list does.
    spaced: bool,
}

impl Repair {
    /// Splices the missing text into `sql`, keeping the words either side of it
    /// apart.
    fn apply(&self, sql: &mut String) {
        let joined = self.spaced && !sql[..self.at].ends_with(char::is_whitespace);
        let text = if joined {
            format!(" {}", self.text)
        } else {
            self.text.clone()
        };
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
        spaced: true,
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
fn repair_site(tree: &ErasedSegment, table: &str) -> Option<Repair> {
    // A statement that did not parse at all sits unreadable at the root.
    let unnamed = child(tree, SyntaxKind::Unparsable)
        .and_then(|statement| missing_relation(&statement, table));

    let clauses = crawl(tree, SyntaxKind::SelectClause);
    let brackets = crawl(tree, SyntaxKind::Bracketed);

    let missing_from = clauses
        .iter()
        .filter_map(unparsable_child)
        .map(|at| Repair {
            at,
            text: format!("from {table} "),
            spaced: true,
        });

    let missing_select = brackets
        .iter()
        .filter(|bracket| unparsable_child(bracket).is_some())
        .filter_map(|bracket| child(bracket, SyntaxKind::StartBracket))
        .filter_map(|opened| span(&opened).map(|at| at.end))
        .map(|at| Repair {
            at,
            text: "select ".to_string(),
            spaced: false,
        });

    unnamed
        .into_iter()
        .chain(missing_from)
        .chain(missing_select)
        .min_by_key(|site| site.at)
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
/// `supply` is the caller's: a statement already opening with a query keyword
/// must be left as it is, because a keyword this dialect does not know reads
/// perfectly well as a column name -- `describe` would quietly become
/// `select describe`.
fn completed(
    linter: &Linter,
    statement: &str,
    supply: bool,
    table: &str,
) -> Option<(&'static str, String, ErasedSegment, usize)> {
    let prefixes: &[&'static str] = if supply { &PREFIXES } else { &PREFIXES[..1] };

    for &prefix in prefixes {
        let mut candidate = format!("{prefix}{statement}");

        for repairs in 0..=MAX_REPAIRS {
            let Some(tree) = parse(linter, &candidate) else {
                break;
            };
            if usable(&tree, &candidate) {
                return Some((prefix, candidate, tree, repairs));
            }
            if repairs == MAX_REPAIRS {
                break; // one more mend could not be checked anyway
            }
            let Some(site) = repair_site(&tree, table) else {
                break; // unreadable for a reason no insertion will mend
            };
            site.apply(&mut candidate);
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
        injected: usize,
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

    // The one thing decided before there is a parse to read: whether a SELECT
    // may be put in front. Everything a statement is missing *within* itself is
    // found by parsing it and mending what the parse points at.
    let opening = opening_word(config, statement);
    let supply = !opens_a_query(&opening) && !mutates(&opening);

    let Some((prefix, candidate, tree, repairs)) = completed(&linter, statement, supply, table)
    else {
        return Answer::refused("sqruff could not read the whole statement");
    };

    let mut insertions = missing_froms(&tree);
    let mut sql = candidate;
    let addition = format!(" from {table}");

    // Highest offset first, so each insertion leaves the ones still to come
    // where the parse found them. Tree order will not do: a nested SELECT is
    // crawled after the one holding it but sits earlier in the text.
    insertions.sort_unstable();
    for at in insertions.iter().rev() {
        sql.insert_str(*at, &addition);
    }

    Answer::Completed {
        ok: true,
        sql,
        strategy: if repairs == 0 {
            Strategy::Parsed
        } else {
            Strategy::Repaired
        },
        repairs,
        injected: insertions.len(),
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
