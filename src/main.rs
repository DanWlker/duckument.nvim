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
//!     {"sql": ...}
//!     {"error": ...}
//!
//! What the completed statement *does* with the buffer is not reported: it
//! opens with the keyword that says so, every repair having already been made,
//! so the caller can read it off the first word without parsing anything.

mod answer;
mod checks;
mod fix;
mod repair;
mod tree;

use std::io::Read;

use crate::answer::{Answer, Request};
use crate::fix::try_fix;

fn main() {
    let mut input = String::new();
    let answer = if std::io::stdin().read_to_string(&mut input).is_err() {
        Answer::refused("could not read stdin")
    } else {
        match serde_json::from_str::<Request>(&input) {
            Ok(request) => try_fix(request.statement(), request.table()),
            Err(why) => Answer::refused(why.to_string()),
        }
    };

    println!("{}", serde_json::to_string(&answer).unwrap());
}
