//! Completing a statement: parse it, mend what the parse points at, parse it
//! again, and stop when there is nothing left to mend.

use sqruff_lib::core::config::FluffConfig;
use sqruff_lib::core::linter::core::Linter;
use sqruff_lib_core::parser::segments::{ErasedSegment, Tables};

use crate::answer::Answer;
use crate::checks::usable;
use crate::repair::repair_sites;
use crate::tree::{lex, span};

/// What may be put in front of a statement typed without a SELECT. Nothing
/// first, since a statement that already reads is not to be touched; then the
/// bare list form, then the bare clause form.
const PREFIXES: [&str; 3] = ["", "select ", "select * "];

/// How many times a statement may be mended before we call it unreadable. Each
/// round fixes one level, and a statement nested deeper than this is not one
/// anybody typed at a `:Duck` prompt.
const MAX_REPAIRS: usize = 16;

/// The completed statement, or why there is none.
pub(crate) fn try_fix(statement: &str, table: &str) -> Answer {
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

    for &prefix in PREFIXES.iter() {
        let mut candidate = format!("{prefix}{statement}");

        for round in 0..=MAX_REPAIRS {
            let Some(tree) = parse(&linter, &candidate) else {
                break;
            };
            if usable(&tree, &candidate) {
                return Answer::Completed { sql: candidate };
            }
            if round == MAX_REPAIRS {
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

    Answer::refused("sqruff could not read the whole statement")
}

/// The tree sqruff makes of `sql`, however much of it it could read.
fn parse(linter: &Linter, sql: &str) -> Option<ErasedSegment> {
    linter
        .parse_string(&Tables::default(), sql, None)
        .ok()?
        .tree
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
