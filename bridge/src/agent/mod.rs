//! Agent session management module
//!
//! Handles spawning and managing Claude Code agent sessions with PTY support.

mod manager;
mod session;

pub use manager::*;
pub use session::*;
