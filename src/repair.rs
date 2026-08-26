//! What a statement is missing, and where the parse says it goes.
//!
//! Every mend here is *located* by the parse rather than guessed at from the
//! text, and none is trusted until the mended statement has been read again.

use sqruff_lib_core::dialects::syntax::SyntaxKind;
use sqruff_lib_core::parser::segments::ErasedSegment;

use crate::tree::{child, crawl, span, unparsable_child};

/// Somewhere the parse stopped following, and what is missing there.
pub(crate) struct Repair {
    at: usize,
    text: String,
}

impl Repair {
    /// Splices the missing text into `sql`, keeping it apart from the words
    /// either side of it -- and only from words. An opening bracket is already
    /// a separator, and punctuation on the far side needs none, so neither
    /// gains a space it did not have.
    pub(crate) fn apply(&self, sql: &mut String) {
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

/// Everywhere a statement needs mending, as far as this one parse can show.
///
/// Three shapes, each of which the parse points straight at:
///
/// A **SELECT that named no source** wants a FROM. It goes where the select
/// list actually ended: at the word the list could not take, if it ran on past
/// the clause that should have stopped it, and at the end of the clause
/// otherwise -- a runaway clause ends where the statement does, which is not
/// where a FROM belongs. GROUP BY and HAVING do not end a select list the way
/// WHERE and ORDER BY do, which is how a list comes to run on at all.
///
/// A **bracket holding something unreadable** is a subquery written without its
/// SELECT: `(b where c > 1)` parses as far as `b` and no further.
///
/// A **whole statement the parser could not read**, opening with a keyword that
/// acts on a relation, never named the relation: `update set x = 1`, `describe`.
///
/// Sites inside an unreadable stretch are not here: everything past one is held
/// as raw words rather than parsed, so they only appear once the stretch itself
/// has been mended and the statement read again.
pub(crate) fn repair_sites(tree: &ErasedSegment, table: &str) -> Vec<Repair> {
    // A statement that did not parse at all sits unreadable at the root.
    let unnamed = child(tree, SyntaxKind::Unparsable)
        .and_then(|statement| missing_relation(&statement, table));

    let selects = crawl(tree, SyntaxKind::SelectStatement);
    let brackets = crawl(tree, SyntaxKind::Bracketed);

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
