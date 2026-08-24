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

use serde_json::{json, Value};
use sqruff_lib::core::config::FluffConfig;
use sqruff_lib::core::linter::core::Linter;
use sqruff_lib_core::dialects::syntax::{SyntaxKind, SyntaxSet};
use sqruff_lib_core::parser::segments::{ErasedSegment, Tables};

/// Keywords that may open a query on their own. Anything else means the
/// statement was typed as a bare select list, or a bare clause.
const OPENING: [&str; 9] = [
    "select",
    "with",
    "from",
    "describe",
    "summarize",
    "pivot",
    "unpivot",
    "table",
    "values",
];

/// Statements that write rather than read.
const MUTATION: [&str; 3] = ["update", "delete", "insert"];

/// Statements taking the buffer as their one operand: `DESCRIBE this`,
/// `SUMMARIZE this`. Written bare, there is nothing in the text for a parser to
/// find, so the buffer is named for them -- the same repair a mutation's target
/// needs, and checked the same way, by parsing what it produced.
const NEEDS_OPERAND: [&str; 2] = ["describe", "summarize"];

/// A bare word sitting at paren depth zero, and where it ends -- which is where
/// the name of a mutation's target has to go.
struct Word {
    text: String,
    end: usize,
}

/// The depth-zero words of a statement, which is all that is read here: what it
/// opens with, and what a mutation writes to. Strings and comments never appear
/// -- the lexer hands those back whole, so a keyword written inside one is not a
/// keyword to us either.
struct Scan {
    words: Vec<Word>,
}

fn scan(config: &FluffConfig, sql: &str) -> Scan {
    let lexer = config.get_dialect().lexer();
    let tables = Tables::default();
    let (segments, _errors) = lexer.lex(&tables, sql);

    let mut words = Vec::new();
    let mut depth = 0usize;

    for segment in &segments {
        let Some(marker) = segment.get_position_marker() else {
            continue;
        };
        let end = marker.source_slice.end;

        match segment.get_type() {
            SyntaxKind::StartBracket => depth += 1,
            SyntaxKind::EndBracket => depth = depth.saturating_sub(1),
            SyntaxKind::Word if depth == 0 => words.push(Word {
                text: segment.raw().to_lowercase(),
                end,
            }),
            _ => {}
        }
    }

    Scan { words }
}

fn first_word(scan: &Scan) -> &str {
    scan.words.first().map_or("", |word| word.text.as_str())
}

/// Names `table` as the target of a mutation that left its own out:
/// `update set x = 1`, `delete where x`, `insert values (...)`.
///
/// This is the one repair no parser can make for us -- there is no table in the
/// text to find -- so it happens before anything tries to read the statement.
fn name_target(sql: &str, scan: &Scan, table: &str) -> String {
    let Some(head) = scan.words.first() else {
        return sql.to_string();
    };
    let next = scan.words.get(1).map(|word| word.text.as_str());

    let addition = match head.text.as_str() {
        "update" if next == Some("set") => format!(" {table}"),
        "delete" if next != Some("from") => format!(" from {table}"),
        "insert" if next != Some("into") => format!(" into {table}"),
        _ => return sql.to_string(), // it already names what it writes to
    };

    let mut named = sql.to_string();
    named.insert_str(head.end, &addition);
    named
}

/// Everything but the comments.
///
/// A comment cannot survive being completed -- a FROM appended to a statement
/// ending in `-- note` lands inside the note -- and it means nothing to duckdb
/// either, so it goes before any of this starts. Only real comments go: the
/// lexer hands a string literal back whole, so `'-- not a comment'` is left
/// exactly where it is.
fn strip_comments(config: &FluffConfig, sql: &str) -> String {
    let lexer = config.get_dialect().lexer();
    let tables = Tables::default();
    let (segments, _errors) = lexer.lex(&tables, sql);

    let mut stripped = sql.to_string();

    // Back to front, so the ranges still ahead stay valid.
    for segment in segments.iter().rev() {
        if !matches!(
            segment.get_type(),
            SyntaxKind::InlineComment | SyntaxKind::BlockComment
        ) {
            continue;
        }
        if let Some(marker) = segment.get_position_marker() {
            stripped.replace_range(marker.source_slice.clone(), "");
        }
    }

    stripped
}

/// Where a missing FROM belongs in one SELECT: just past its select clause.
fn missing_froms(tree: &ErasedSegment) -> Vec<usize> {
    let selects = tree.recursive_crawl(
        &SyntaxSet::new(&[SyntaxKind::SelectStatement]),
        true,
        &SyntaxSet::EMPTY,
        true,
    );

    let mut found = Vec::new();
    for select in selects {
        let children = select.segments();
        if children
            .iter()
            .any(|child| child.get_type() == SyntaxKind::FromClause)
        {
            continue;
        }

        // The FROM follows the select clause, so the end of that clause is the
        // one position that is right whatever else the statement holds.
        let clause = children
            .iter()
            .find(|child| child.get_type() == SyntaxKind::SelectClause);

        let marker = clause.and_then(|clause| clause.get_position_marker());
        if let Some(marker) = marker {
            found.push(marker.source_slice.end);
        }
    }

    found
}

/// True when every SELECT in `tree` actually selects something.
///
/// This is the check that makes supplying the SELECT safe. sqruff parses
/// `select where a > 1` quite happily -- an empty projection is valid grammar --
/// and duckdb then rejects `select from this where a > 1`. A tree that parses is
/// therefore not yet a tree that can be fixed; one with nothing between SELECT
/// and the next clause has to be turned down so the next candidate is tried.
fn projections_are_present(tree: &ErasedSegment) -> bool {
    let selects = tree.recursive_crawl(
        &SyntaxSet::new(&[SyntaxKind::SelectStatement]),
        true,
        &SyntaxSet::EMPTY,
        true,
    );

    selects.iter().all(|select| {
        select
            .segments()
            .iter()
            .find(|child| child.get_type() == SyntaxKind::SelectClause)
            .is_some_and(|clause| {
                clause
                    .segments()
                    .iter()
                    .any(|child| child.get_type() == SyntaxKind::SelectClauseElement)
            })
    })
}

/// True when sqruff could not read part of the statement. Its guess about the
/// rest is not worth splicing into.
fn has_unparsable(tree: &ErasedSegment) -> bool {
    !tree
        .recursive_crawl(
            &SyntaxSet::new(&[SyntaxKind::Unparsable]),
            true,
            &SyntaxSet::EMPTY,
            true,
        )
        .is_empty()
}

/// What may be put in front of a statement typed without a SELECT. Nothing
/// first, since a statement that already reads is not to be touched; then the
/// bare list form, then the bare clause form.
const PREFIXES: [&str; 3] = ["", "select ", "select * "];

/// The first prefix under which the whole statement reads, with its tree.
///
/// `supply` is the caller's: a statement already opening with a query keyword
/// must be left as it is, because a keyword this dialect does not know reads
/// perfectly well as a column name -- `describe` would quietly become
/// `select describe`.
fn readable(
    linter: &Linter,
    statement: &str,
    supply: bool,
) -> Option<(&'static str, String, ErasedSegment)> {
    let prefixes: &[&'static str] = if supply { &PREFIXES } else { &PREFIXES[..1] };

    for &prefix in prefixes {
        let candidate = format!("{prefix}{statement}");
        let tables = Tables::default();

        let Ok(parsed) = linter.parse_string(&tables, &candidate, None) else {
            continue;
        };
        let Some(tree) = parsed.tree else { continue };

        if !has_unparsable(&tree) && projections_are_present(&tree) {
            return Some((prefix, candidate, tree));
        }
    }

    None
}

fn complete(statement: &str, table: &str) -> Value {
    let config = FluffConfig::from_source("[sqruff]\ndialect = duckdb\n", None);
    let linter = match Linter::new(config.clone(), None, None, false) {
        Ok(linter) => linter,
        Err(why) => return json!({ "ok": false, "error": why }),
    };

    let stripped = strip_comments(&config, statement);
    let trimmed = stripped.trim();
    let statement = if trimmed.is_empty() { "*" } else { trimmed };

    let scanned = scan(&config, statement);
    let first = first_word(&scanned).to_string();
    let writes = MUTATION.contains(&first.as_str());

    // A mutation is named before anything reads it, and never prefixed.
    let mut named = name_target(statement, &scanned, table);
    let supply = !writes && !OPENING.contains(&first.as_str());

    // A bare DESCRIBE or SUMMARIZE has nothing to work on. Both take a table,
    // and the buffer is one, so name it.
    if NEEDS_OPERAND.contains(&first.as_str()) && scanned.words.len() == 1 {
        named = format!("{named} {table}");
    }

    if let Some((prefix, candidate, tree)) = readable(&linter, &named, supply) {
        let mut insertions = missing_froms(&tree);
        let mut sql = candidate;
        let addition = format!(" from {table}");

        // Highest offset first, so each insertion leaves the ones still to come
        // where the parse found them. Tree order will not do: a nested SELECT is
        // crawled after the one holding it but sits earlier in the text.
        insertions.sort_unstable_by(|a, b| b.cmp(a));
        for at in &insertions {
            sql.insert_str(*at, &addition);
        }

        return json!({
            "ok": true,
            "sql": sql,
            "strategy": "parsed",
            "injected": insertions.len(),
            "supplied": if prefix.is_empty() {
                Value::Null
            } else {
                json!(prefix)
            },
        });
    }

    json!({ "ok": false, "error": "sqruff could not read the whole statement" })
}

fn main() {
    let mut input = String::new();
    if std::io::stdin().read_to_string(&mut input).is_err() {
        println!(
            "{}",
            json!({ "ok": false, "error": "could not read stdin" })
        );
        return;
    }

    let payload: Value = match serde_json::from_str(&input) {
        Ok(payload) => payload,
        Err(why) => {
            println!("{}", json!({ "ok": false, "error": why.to_string() }));
            return;
        }
    };

    let statement = payload["statement"].as_str().unwrap_or("");
    let table = payload["table"].as_str().unwrap_or("this");

    println!("{}", complete(statement, table));
}
