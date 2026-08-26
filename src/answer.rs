//! What comes in on stdin and what goes back out on stdout.

use serde::{Deserialize, Serialize};

/// What was asked for: a statement, and the name the buffer answers to.
///
/// Both are optional twice over: absent, and present as null. A caller whose
/// JSON encoder writes an unset field out as `null` rather than leaving it off
/// means the same thing by it, and is answered the same way.
#[derive(Deserialize)]
pub(crate) struct Request {
    #[serde(default)]
    statement: Option<String>,
    #[serde(default)]
    table: Option<String>,
}

impl Request {
    pub(crate) fn statement(&self) -> &str {
        self.statement.as_deref().unwrap_or("")
    }

    pub(crate) fn table(&self) -> &str {
        self.table.as_deref().unwrap_or("this")
    }
}

/// What is written back: the statement, or why there is none. Which one it is
/// the caller reads off the field that is there.
#[derive(Serialize)]
#[serde(untagged)]
pub(crate) enum Answer {
    Completed { sql: String },
    Refused { error: String },
}

impl Answer {
    pub(crate) fn refused(why: impl Into<String>) -> Self {
        Answer::Refused { error: why.into() }
    }
}
