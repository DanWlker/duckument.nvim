//! Getting about a sqruff parse tree, and the lexer underneath it.
//!
//! Nothing here knows what a statement is missing; it only answers where things
//! are and what is under them.

use std::ops::Range;

use sqruff_lib::core::config::FluffConfig;
use sqruff_lib_core::dialects::syntax::{SyntaxKind, SyntaxSet};
use sqruff_lib_core::parser::segments::{ErasedSegment, Tables};

/// Every descendant of `segment` of this kind, `segment` itself included.
pub(crate) fn crawl(segment: &ErasedSegment, kind: SyntaxKind) -> Vec<ErasedSegment> {
    segment.recursive_crawl(&SyntaxSet::single(kind), true, &SyntaxSet::EMPTY, true)
}

/// The child of `segment` of this kind, if it has one.
pub(crate) fn child(segment: &ErasedSegment, kind: SyntaxKind) -> Option<ErasedSegment> {
    segment.child(&SyntaxSet::single(kind))
}

/// Where `segment` sits in the text it was read from.
pub(crate) fn span(segment: &ErasedSegment) -> Option<Range<usize>> {
    segment
        .get_position_marker()
        .map(|marker| marker.source_slice.clone())
}

/// Where the first unreadable child of `segment` starts.
pub(crate) fn unparsable_child(segment: &ErasedSegment) -> Option<usize> {
    child(segment, SyntaxKind::Unparsable)
        .and_then(|unreadable| span(&unreadable))
        .map(|at| at.start)
}

/// The statement in tokens, strings and comments each held whole.
pub(crate) fn lex(config: &FluffConfig, sql: &str) -> Vec<ErasedSegment> {
    let tables = Tables::default();
    let (segments, _errors) = config.get_dialect().lexer().lex(&tables, sql);
    segments
}
