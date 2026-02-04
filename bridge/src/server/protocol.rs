//! Protocol message definitions
//!
//! Defines the message types exchanged between Godot clients and the bridge server.

use serde::{Deserialize, Serialize};
use uuid::Uuid;

/// Protocol version for compatibility checking
pub const PROTOCOL_VERSION: u32 = 1;

/// Messages sent from client to server
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(tag = "type", rename_all = "snake_case")]
pub enum ClientMessage {
    /// Ping for connection keepalive
    Ping { seq: u64 },
    /// Request to spawn a new agent
    SpawnAgent {
        project_path: String,
        preset: Option<String>,
    },
    /// Send input to an agent
    AgentInput { agent_id: Uuid, input: String },
    /// Request to kill an agent
    KillAgent { agent_id: Uuid },
    /// Resize agent terminal
    ResizeTerminal {
        agent_id: Uuid,
        cols: u16,
        rows: u16,
    },
}

/// Messages sent from server to client
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(tag = "type", rename_all = "snake_case")]
pub enum ServerMessage {
    /// Response to ping
    Pong { seq: u64 },
    /// Agent spawned successfully
    AgentSpawned { agent_id: Uuid, project_path: String },
    /// Agent output data
    AgentOutput { agent_id: Uuid, data: String },
    /// Agent exited
    AgentExited { agent_id: Uuid, exit_code: Option<i32> },
    /// Error occurred
    Error { message: String, agent_id: Option<Uuid> },
    /// Welcome message with protocol version
    Welcome { version: u32 },
}
