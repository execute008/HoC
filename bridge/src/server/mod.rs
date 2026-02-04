//! WebSocket server module
//!
//! Handles WebSocket connections from Godot clients and routes messages
//! to the appropriate handlers.

#[allow(dead_code)]
mod handler;
mod protocol;
mod websocket;

#[allow(unused_imports)]
pub use protocol::{
    AgentInfo, AgentState, ClientMessage, ErrorCode, ServerMessage, PROTOCOL_VERSION,
};
pub use websocket::{ServerConfig, WebSocketServer};
