//! WebSocket server module
//!
//! Handles WebSocket connections from Godot clients and routes messages
//! to the appropriate handlers.

#[allow(dead_code)]
mod handler;
#[allow(dead_code)]
mod protocol;

#[allow(unused_imports)]
pub use handler::*;
#[allow(unused_imports)]
pub use protocol::*;
