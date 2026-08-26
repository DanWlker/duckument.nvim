//! Whether a parse is one to finish a statement from.
//!
//! Four things have to hold, and each catches a way a tree can look healthier
//! than it is. Together they are what stops a repair being spliced into text
//! the parse never understood.

use sqruff_lib_core::dialects::syntax::SyntaxKind;
use sqruff_lib_core::parser::segments::ErasedSegment;

use crate::tree::{child, crawl, span};

/// Whether `tree` is one to finish a statement from: it accounts for all of
/// `sql`, was read in full, and every SELECT in it actually selects something.
pub(crate) fn usable(tree: &ErasedSegment, sql: &str) -> bool {
    covers(tree, sql)
        && !has_unparsable(tree) // DESCRIBE, UPDATE, DELETE already stops here
        && projections_are_present(tree)
        && sources_are_named(tree) // SELECT can be SELECT 1, but this plugin is for querying a csv
                                   // so by default the assumption is SELECT without from-ing this
                                   // csv file is dumb
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

/// True when sqruff could not read part of the statement. Its guess about the
/// rest is not worth splicing into.
fn has_unparsable(tree: &ErasedSegment) -> bool {
    !crawl(tree, SyntaxKind::Unparsable).is_empty()
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
