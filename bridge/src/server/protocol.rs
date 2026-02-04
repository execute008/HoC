//! Protocol message definitions
//!
//! Defines the message types exchanged between Godot clients and the bridge server.
//! All messages are JSON-encoded and include version information for compatibility.

use serde::{Deserialize, Serialize};
use thiserror::Error;
use uuid::Uuid;

/// Current protocol version
/// Increment when making breaking changes to message format
pub const PROTOCOL_VERSION: u32 = 1;

/// Minimum supported protocol version
pub const MIN_PROTOCOL_VERSION: u32 = 1;

/// Maximum terminal dimensions
pub const MAX_TERMINAL_COLS: u16 = 500;
pub const MAX_TERMINAL_ROWS: u16 = 200;

/// Default terminal dimensions
pub const DEFAULT_TERMINAL_COLS: u16 = 80;
pub const DEFAULT_TERMINAL_ROWS: u16 = 24;

/// Maximum input length (1MB)
pub const MAX_INPUT_LENGTH: usize = 1024 * 1024;

/// Maximum path length
pub const MAX_PATH_LENGTH: usize = 4096;

/// Maximum preset name length
pub const MAX_PRESET_NAME_LENGTH: usize = 256;

// ============================================================================
// Error Types
// ============================================================================

/// Protocol-related errors
#[derive(Debug, Error)]
pub enum ProtocolError {
    #[error("JSON serialization error: {0}")]
    SerializationError(#[from] serde_json::Error),

    #[error("Protocol version {0} not supported (min: {MIN_PROTOCOL_VERSION}, current: {PROTOCOL_VERSION})")]
    UnsupportedVersion(u32),

    #[error("Invalid message: {0}")]
    InvalidMessage(String),

    #[error("Validation error: {0}")]
    ValidationError(String),
}

/// Result type for protocol operations
pub type ProtocolResult<T> = Result<T, ProtocolError>;

// ============================================================================
// Message Envelope
// ============================================================================

/// Protocol envelope wrapping all client messages
/// Includes version for compatibility checking
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ClientEnvelope {
    /// Protocol version used by the client
    #[serde(default = "default_version")]
    pub version: u32,
    /// The actual message payload
    #[serde(flatten)]
    pub message: ClientMessage,
}

/// Protocol envelope wrapping all server messages
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ServerEnvelope {
    /// Protocol version used by the server
    pub version: u32,
    /// The actual message payload
    #[serde(flatten)]
    pub message: ServerMessage,
}

fn default_version() -> u32 {
    PROTOCOL_VERSION
}

impl ClientEnvelope {
    /// Create a new client envelope with the current protocol version
    pub fn new(message: ClientMessage) -> Self {
        Self {
            version: PROTOCOL_VERSION,
            message,
        }
    }

    /// Parse and validate a client envelope from JSON
    pub fn from_json(json: &str) -> ProtocolResult<Self> {
        let envelope: Self = serde_json::from_str(json)?;
        envelope.validate()?;
        Ok(envelope)
    }

    /// Validate the envelope and its contents
    pub fn validate(&self) -> ProtocolResult<()> {
        // Check protocol version
        if self.version < MIN_PROTOCOL_VERSION {
            return Err(ProtocolError::UnsupportedVersion(self.version));
        }

        // Validate the message contents
        self.message.validate()
    }

    /// Serialize the envelope to JSON
    pub fn to_json(&self) -> ProtocolResult<String> {
        Ok(serde_json::to_string(self)?)
    }
}

impl ServerEnvelope {
    /// Create a new server envelope with the current protocol version
    pub fn new(message: ServerMessage) -> Self {
        Self {
            version: PROTOCOL_VERSION,
            message,
        }
    }

    /// Serialize the envelope to JSON
    pub fn to_json(&self) -> ProtocolResult<String> {
        Ok(serde_json::to_string(self)?)
    }

    /// Parse a server envelope from JSON (primarily for testing)
    pub fn from_json(json: &str) -> ProtocolResult<Self> {
        Ok(serde_json::from_str(json)?)
    }
}

// ============================================================================
// Client Messages
// ============================================================================

/// Messages sent from client (Godot) to server
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(tag = "type", rename_all = "snake_case")]
pub enum ClientMessage {
    /// Connection keepalive ping
    Ping {
        /// Sequence number for tracking round-trip time
        seq: u64,
    },

    /// Request to spawn a new agent session
    SpawnAgent {
        /// Path to the project directory
        project_path: String,
        /// Optional preset name from project config
        #[serde(skip_serializing_if = "Option::is_none")]
        preset: Option<String>,
        /// Optional initial terminal columns
        #[serde(skip_serializing_if = "Option::is_none")]
        cols: Option<u16>,
        /// Optional initial terminal rows
        #[serde(skip_serializing_if = "Option::is_none")]
        rows: Option<u16>,
    },

    /// Send input to an existing agent
    AgentInput {
        /// UUID of the target agent
        agent_id: Uuid,
        /// Input data to send to the agent's stdin
        input: String,
    },

    /// Request to terminate an agent
    KillAgent {
        /// UUID of the agent to terminate
        agent_id: Uuid,
        /// Optional signal to send (default: SIGTERM)
        #[serde(skip_serializing_if = "Option::is_none")]
        signal: Option<i32>,
    },

    /// Resize an agent's terminal
    ResizeTerminal {
        /// UUID of the target agent
        agent_id: Uuid,
        /// New terminal width in columns
        cols: u16,
        /// New terminal height in rows
        rows: u16,
    },

    /// List all active agents
    ListAgents,

    /// Request agent status
    GetAgentStatus {
        /// UUID of the agent to query
        agent_id: Uuid,
    },
}

impl ClientMessage {
    /// Validate message contents
    pub fn validate(&self) -> ProtocolResult<()> {
        match self {
            ClientMessage::Ping { .. } => Ok(()),

            ClientMessage::SpawnAgent {
                project_path,
                preset,
                cols,
                rows,
            } => {
                // Validate project path
                if project_path.is_empty() {
                    return Err(ProtocolError::ValidationError(
                        "project_path cannot be empty".to_string(),
                    ));
                }
                if project_path.len() > MAX_PATH_LENGTH {
                    return Err(ProtocolError::ValidationError(format!(
                        "project_path exceeds maximum length of {} characters",
                        MAX_PATH_LENGTH
                    )));
                }

                // Validate preset name
                if let Some(p) = preset {
                    if p.is_empty() {
                        return Err(ProtocolError::ValidationError(
                            "preset name cannot be empty when specified".to_string(),
                        ));
                    }
                    if p.len() > MAX_PRESET_NAME_LENGTH {
                        return Err(ProtocolError::ValidationError(format!(
                            "preset name exceeds maximum length of {} characters",
                            MAX_PRESET_NAME_LENGTH
                        )));
                    }
                }

                // Validate terminal dimensions
                if let Some(c) = cols {
                    if *c == 0 || *c > MAX_TERMINAL_COLS {
                        return Err(ProtocolError::ValidationError(format!(
                            "cols must be between 1 and {}",
                            MAX_TERMINAL_COLS
                        )));
                    }
                }
                if let Some(r) = rows {
                    if *r == 0 || *r > MAX_TERMINAL_ROWS {
                        return Err(ProtocolError::ValidationError(format!(
                            "rows must be between 1 and {}",
                            MAX_TERMINAL_ROWS
                        )));
                    }
                }

                Ok(())
            }

            ClientMessage::AgentInput { input, .. } => {
                if input.len() > MAX_INPUT_LENGTH {
                    return Err(ProtocolError::ValidationError(format!(
                        "input exceeds maximum length of {} bytes",
                        MAX_INPUT_LENGTH
                    )));
                }
                Ok(())
            }

            ClientMessage::KillAgent { signal, .. } => {
                // Validate signal is reasonable (common Unix signals)
                if let Some(sig) = signal {
                    if *sig < 1 || *sig > 31 {
                        return Err(ProtocolError::ValidationError(format!(
                            "signal {} is not a valid Unix signal (1-31)",
                            sig
                        )));
                    }
                }
                Ok(())
            }

            ClientMessage::ResizeTerminal { cols, rows, .. } => {
                if *cols == 0 || *cols > MAX_TERMINAL_COLS {
                    return Err(ProtocolError::ValidationError(format!(
                        "cols must be between 1 and {}",
                        MAX_TERMINAL_COLS
                    )));
                }
                if *rows == 0 || *rows > MAX_TERMINAL_ROWS {
                    return Err(ProtocolError::ValidationError(format!(
                        "rows must be between 1 and {}",
                        MAX_TERMINAL_ROWS
                    )));
                }
                Ok(())
            }

            ClientMessage::ListAgents => Ok(()),

            ClientMessage::GetAgentStatus { .. } => Ok(()),
        }
    }

    /// Create a Ping message
    pub fn ping(seq: u64) -> Self {
        ClientMessage::Ping { seq }
    }

    /// Create a SpawnAgent message
    pub fn spawn_agent(project_path: impl Into<String>) -> Self {
        ClientMessage::SpawnAgent {
            project_path: project_path.into(),
            preset: None,
            cols: None,
            rows: None,
        }
    }

    /// Create a SpawnAgent message with preset
    pub fn spawn_agent_with_preset(
        project_path: impl Into<String>,
        preset: impl Into<String>,
    ) -> Self {
        ClientMessage::SpawnAgent {
            project_path: project_path.into(),
            preset: Some(preset.into()),
            cols: None,
            rows: None,
        }
    }

    /// Create an AgentInput message
    pub fn agent_input(agent_id: Uuid, input: impl Into<String>) -> Self {
        ClientMessage::AgentInput {
            agent_id,
            input: input.into(),
        }
    }

    /// Create a KillAgent message
    pub fn kill_agent(agent_id: Uuid) -> Self {
        ClientMessage::KillAgent {
            agent_id,
            signal: None,
        }
    }

    /// Create a ResizeTerminal message
    pub fn resize_terminal(agent_id: Uuid, cols: u16, rows: u16) -> Self {
        ClientMessage::ResizeTerminal {
            agent_id,
            cols,
            rows,
        }
    }
}

// ============================================================================
// Server Messages
// ============================================================================

/// Messages sent from server to client (Godot)
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(tag = "type", rename_all = "snake_case")]
pub enum ServerMessage {
    /// Welcome message sent on connection
    Welcome {
        /// Server protocol version
        version: u32,
        /// Server identifier/name
        #[serde(skip_serializing_if = "Option::is_none")]
        server_id: Option<String>,
    },

    /// Response to Ping
    Pong {
        /// Echo back the sequence number
        seq: u64,
    },

    /// Agent successfully spawned
    AgentSpawned {
        /// UUID of the new agent
        agent_id: Uuid,
        /// Confirmed project path
        project_path: String,
        /// Terminal columns
        cols: u16,
        /// Terminal rows
        rows: u16,
    },

    /// Output data from an agent
    AgentOutput {
        /// UUID of the source agent
        agent_id: Uuid,
        /// Output data (may contain ANSI escape sequences)
        data: String,
    },

    /// Agent process exited
    AgentExited {
        /// UUID of the exited agent
        agent_id: Uuid,
        /// Exit code if available
        #[serde(skip_serializing_if = "Option::is_none")]
        exit_code: Option<i32>,
        /// Exit reason description
        #[serde(skip_serializing_if = "Option::is_none")]
        reason: Option<String>,
    },

    /// Agent terminal resized
    AgentResized {
        /// UUID of the agent
        agent_id: Uuid,
        /// New terminal columns
        cols: u16,
        /// New terminal rows
        rows: u16,
    },

    /// List of active agents
    AgentList {
        /// List of agent information
        agents: Vec<AgentInfo>,
    },

    /// Status of a specific agent
    AgentStatus {
        /// UUID of the agent
        agent_id: Uuid,
        /// Current status
        status: AgentState,
        /// Project path
        project_path: String,
        /// Terminal columns
        cols: u16,
        /// Terminal rows
        rows: u16,
    },

    /// Error response
    Error {
        /// Error message
        message: String,
        /// Error code for programmatic handling
        #[serde(skip_serializing_if = "Option::is_none")]
        code: Option<ErrorCode>,
        /// Related agent UUID if applicable
        #[serde(skip_serializing_if = "Option::is_none")]
        agent_id: Option<Uuid>,
    },
}

/// Information about an agent for listing
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct AgentInfo {
    /// Agent UUID
    pub agent_id: Uuid,
    /// Project path
    pub project_path: String,
    /// Current state
    pub status: AgentState,
    /// Terminal columns
    pub cols: u16,
    /// Terminal rows
    pub rows: u16,
}

/// Agent lifecycle states
#[derive(Debug, Clone, Copy, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum AgentState {
    /// Agent is starting up
    Starting,
    /// Agent is running and accepting input
    Running,
    /// Agent is shutting down
    Stopping,
    /// Agent has stopped
    Stopped,
}

/// Error codes for programmatic error handling
#[derive(Debug, Clone, Copy, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum ErrorCode {
    /// Invalid message format
    InvalidMessage,
    /// Agent not found
    AgentNotFound,
    /// Failed to spawn agent
    SpawnFailed,
    /// Authentication required
    AuthRequired,
    /// Authentication failed
    AuthFailed,
    /// Rate limited
    RateLimited,
    /// Internal server error
    InternalError,
    /// Invalid project path
    InvalidPath,
    /// Unsupported protocol version
    UnsupportedVersion,
}

impl ServerMessage {
    /// Create a Welcome message
    pub fn welcome() -> Self {
        ServerMessage::Welcome {
            version: PROTOCOL_VERSION,
            server_id: None,
        }
    }

    /// Create a Welcome message with server ID
    pub fn welcome_with_id(server_id: impl Into<String>) -> Self {
        ServerMessage::Welcome {
            version: PROTOCOL_VERSION,
            server_id: Some(server_id.into()),
        }
    }

    /// Create a Pong message
    pub fn pong(seq: u64) -> Self {
        ServerMessage::Pong { seq }
    }

    /// Create an AgentSpawned message
    pub fn agent_spawned(
        agent_id: Uuid,
        project_path: impl Into<String>,
        cols: u16,
        rows: u16,
    ) -> Self {
        ServerMessage::AgentSpawned {
            agent_id,
            project_path: project_path.into(),
            cols,
            rows,
        }
    }

    /// Create an AgentOutput message
    pub fn agent_output(agent_id: Uuid, data: impl Into<String>) -> Self {
        ServerMessage::AgentOutput {
            agent_id,
            data: data.into(),
        }
    }

    /// Create an AgentExited message
    pub fn agent_exited(agent_id: Uuid, exit_code: Option<i32>) -> Self {
        ServerMessage::AgentExited {
            agent_id,
            exit_code,
            reason: None,
        }
    }

    /// Create an AgentExited message with reason
    pub fn agent_exited_with_reason(
        agent_id: Uuid,
        exit_code: Option<i32>,
        reason: impl Into<String>,
    ) -> Self {
        ServerMessage::AgentExited {
            agent_id,
            exit_code,
            reason: Some(reason.into()),
        }
    }

    /// Create an Error message
    pub fn error(message: impl Into<String>) -> Self {
        ServerMessage::Error {
            message: message.into(),
            code: None,
            agent_id: None,
        }
    }

    /// Create an Error message with code
    pub fn error_with_code(message: impl Into<String>, code: ErrorCode) -> Self {
        ServerMessage::Error {
            message: message.into(),
            code: Some(code),
            agent_id: None,
        }
    }

    /// Create an Error message for a specific agent
    pub fn agent_error(agent_id: Uuid, message: impl Into<String>, code: ErrorCode) -> Self {
        ServerMessage::Error {
            message: message.into(),
            code: Some(code),
            agent_id: Some(agent_id),
        }
    }
}

// ============================================================================
// Conversion Traits
// ============================================================================

impl From<ProtocolError> for ServerMessage {
    fn from(err: ProtocolError) -> Self {
        let code = match &err {
            ProtocolError::SerializationError(_) => ErrorCode::InvalidMessage,
            ProtocolError::UnsupportedVersion(_) => ErrorCode::UnsupportedVersion,
            ProtocolError::InvalidMessage(_) => ErrorCode::InvalidMessage,
            ProtocolError::ValidationError(_) => ErrorCode::InvalidMessage,
        };
        ServerMessage::error_with_code(err.to_string(), code)
    }
}

// ============================================================================
// Tests
// ============================================================================

#[cfg(test)]
mod tests {
    use super::*;

    // -------------------------------------------------------------------------
    // Client Message Tests
    // -------------------------------------------------------------------------

    #[test]
    fn test_ping_serialization() {
        let msg = ClientMessage::ping(42);
        let json = serde_json::to_string(&msg).unwrap();
        assert!(json.contains("\"type\":\"ping\""));
        assert!(json.contains("\"seq\":42"));

        let parsed: ClientMessage = serde_json::from_str(&json).unwrap();
        assert_eq!(parsed, msg);
    }

    #[test]
    fn test_spawn_agent_serialization() {
        let msg = ClientMessage::spawn_agent("/path/to/project");
        let json = serde_json::to_string(&msg).unwrap();
        assert!(json.contains("\"type\":\"spawn_agent\""));
        assert!(json.contains("\"project_path\":\"/path/to/project\""));

        let parsed: ClientMessage = serde_json::from_str(&json).unwrap();
        assert_eq!(parsed, msg);
    }

    #[test]
    fn test_spawn_agent_with_preset_serialization() {
        let msg = ClientMessage::spawn_agent_with_preset("/path/to/project", "code-review");
        let json = serde_json::to_string(&msg).unwrap();
        assert!(json.contains("\"preset\":\"code-review\""));

        let parsed: ClientMessage = serde_json::from_str(&json).unwrap();
        assert_eq!(parsed, msg);
    }

    #[test]
    fn test_agent_input_serialization() {
        let agent_id = Uuid::new_v4();
        let msg = ClientMessage::agent_input(agent_id, "hello world");
        let json = serde_json::to_string(&msg).unwrap();
        assert!(json.contains("\"type\":\"agent_input\""));
        assert!(json.contains("\"input\":\"hello world\""));

        let parsed: ClientMessage = serde_json::from_str(&json).unwrap();
        assert_eq!(parsed, msg);
    }

    #[test]
    fn test_kill_agent_serialization() {
        let agent_id = Uuid::new_v4();
        let msg = ClientMessage::kill_agent(agent_id);
        let json = serde_json::to_string(&msg).unwrap();
        assert!(json.contains("\"type\":\"kill_agent\""));

        let parsed: ClientMessage = serde_json::from_str(&json).unwrap();
        assert_eq!(parsed, msg);
    }

    #[test]
    fn test_resize_terminal_serialization() {
        let agent_id = Uuid::new_v4();
        let msg = ClientMessage::resize_terminal(agent_id, 120, 40);
        let json = serde_json::to_string(&msg).unwrap();
        assert!(json.contains("\"type\":\"resize_terminal\""));
        assert!(json.contains("\"cols\":120"));
        assert!(json.contains("\"rows\":40"));

        let parsed: ClientMessage = serde_json::from_str(&json).unwrap();
        assert_eq!(parsed, msg);
    }

    #[test]
    fn test_list_agents_serialization() {
        let msg = ClientMessage::ListAgents;
        let json = serde_json::to_string(&msg).unwrap();
        assert!(json.contains("\"type\":\"list_agents\""));

        let parsed: ClientMessage = serde_json::from_str(&json).unwrap();
        assert_eq!(parsed, msg);
    }

    // -------------------------------------------------------------------------
    // Server Message Tests
    // -------------------------------------------------------------------------

    #[test]
    fn test_welcome_serialization() {
        let msg = ServerMessage::welcome();
        let json = serde_json::to_string(&msg).unwrap();
        assert!(json.contains("\"type\":\"welcome\""));
        assert!(json.contains(&format!("\"version\":{}", PROTOCOL_VERSION)));

        let parsed: ServerMessage = serde_json::from_str(&json).unwrap();
        assert_eq!(parsed, msg);
    }

    #[test]
    fn test_pong_serialization() {
        let msg = ServerMessage::pong(42);
        let json = serde_json::to_string(&msg).unwrap();
        assert!(json.contains("\"type\":\"pong\""));
        assert!(json.contains("\"seq\":42"));

        let parsed: ServerMessage = serde_json::from_str(&json).unwrap();
        assert_eq!(parsed, msg);
    }

    #[test]
    fn test_agent_spawned_serialization() {
        let agent_id = Uuid::new_v4();
        let msg = ServerMessage::agent_spawned(agent_id, "/path/to/project", 80, 24);
        let json = serde_json::to_string(&msg).unwrap();
        assert!(json.contains("\"type\":\"agent_spawned\""));
        assert!(json.contains("\"cols\":80"));
        assert!(json.contains("\"rows\":24"));

        let parsed: ServerMessage = serde_json::from_str(&json).unwrap();
        assert_eq!(parsed, msg);
    }

    #[test]
    fn test_agent_output_serialization() {
        let agent_id = Uuid::new_v4();
        let msg = ServerMessage::agent_output(agent_id, "Hello, World!\n");
        let json = serde_json::to_string(&msg).unwrap();
        assert!(json.contains("\"type\":\"agent_output\""));
        assert!(json.contains("\"data\":\"Hello, World!\\n\""));

        let parsed: ServerMessage = serde_json::from_str(&json).unwrap();
        assert_eq!(parsed, msg);
    }

    #[test]
    fn test_agent_exited_serialization() {
        let agent_id = Uuid::new_v4();
        let msg = ServerMessage::agent_exited(agent_id, Some(0));
        let json = serde_json::to_string(&msg).unwrap();
        assert!(json.contains("\"type\":\"agent_exited\""));
        assert!(json.contains("\"exit_code\":0"));

        let parsed: ServerMessage = serde_json::from_str(&json).unwrap();
        assert_eq!(parsed, msg);
    }

    #[test]
    fn test_error_serialization() {
        let msg = ServerMessage::error_with_code("Something went wrong", ErrorCode::InternalError);
        let json = serde_json::to_string(&msg).unwrap();
        assert!(json.contains("\"type\":\"error\""));
        assert!(json.contains("\"message\":\"Something went wrong\""));
        assert!(json.contains("\"code\":\"internal_error\""));

        let parsed: ServerMessage = serde_json::from_str(&json).unwrap();
        assert_eq!(parsed, msg);
    }

    #[test]
    fn test_agent_list_serialization() {
        let agent_id = Uuid::new_v4();
        let msg = ServerMessage::AgentList {
            agents: vec![AgentInfo {
                agent_id,
                project_path: "/path/to/project".to_string(),
                status: AgentState::Running,
                cols: 80,
                rows: 24,
            }],
        };
        let json = serde_json::to_string(&msg).unwrap();
        assert!(json.contains("\"type\":\"agent_list\""));
        assert!(json.contains("\"status\":\"running\""));

        let parsed: ServerMessage = serde_json::from_str(&json).unwrap();
        assert_eq!(parsed, msg);
    }

    // -------------------------------------------------------------------------
    // Envelope Tests
    // -------------------------------------------------------------------------

    #[test]
    fn test_client_envelope_serialization() {
        let envelope = ClientEnvelope::new(ClientMessage::ping(1));
        let json = envelope.to_json().unwrap();
        assert!(json.contains(&format!("\"version\":{}", PROTOCOL_VERSION)));
        assert!(json.contains("\"type\":\"ping\""));

        let parsed = ClientEnvelope::from_json(&json).unwrap();
        assert_eq!(parsed.version, PROTOCOL_VERSION);
    }

    #[test]
    fn test_server_envelope_serialization() {
        let envelope = ServerEnvelope::new(ServerMessage::pong(1));
        let json = envelope.to_json().unwrap();
        assert!(json.contains(&format!("\"version\":{}", PROTOCOL_VERSION)));
        assert!(json.contains("\"type\":\"pong\""));

        let parsed = ServerEnvelope::from_json(&json).unwrap();
        assert_eq!(parsed.version, PROTOCOL_VERSION);
    }

    #[test]
    fn test_envelope_version_validation() {
        let json = r#"{"version": 0, "type": "ping", "seq": 1}"#;
        let result = ClientEnvelope::from_json(json);
        assert!(result.is_err());
        assert!(result.unwrap_err().to_string().contains("not supported"));
    }

    // -------------------------------------------------------------------------
    // Validation Tests
    // -------------------------------------------------------------------------

    #[test]
    fn test_spawn_agent_empty_path_validation() {
        let msg = ClientMessage::SpawnAgent {
            project_path: "".to_string(),
            preset: None,
            cols: None,
            rows: None,
        };
        let result = msg.validate();
        assert!(result.is_err());
        assert!(result.unwrap_err().to_string().contains("cannot be empty"));
    }

    #[test]
    fn test_spawn_agent_empty_preset_validation() {
        let msg = ClientMessage::SpawnAgent {
            project_path: "/valid/path".to_string(),
            preset: Some("".to_string()),
            cols: None,
            rows: None,
        };
        let result = msg.validate();
        assert!(result.is_err());
        assert!(result
            .unwrap_err()
            .to_string()
            .contains("preset name cannot be empty"));
    }

    #[test]
    fn test_resize_terminal_invalid_cols() {
        let agent_id = Uuid::new_v4();
        let msg = ClientMessage::resize_terminal(agent_id, 0, 24);
        let result = msg.validate();
        assert!(result.is_err());
        assert!(result.unwrap_err().to_string().contains("cols must be"));
    }

    #[test]
    fn test_resize_terminal_invalid_rows() {
        let agent_id = Uuid::new_v4();
        let msg = ClientMessage::resize_terminal(agent_id, 80, 0);
        let result = msg.validate();
        assert!(result.is_err());
        assert!(result.unwrap_err().to_string().contains("rows must be"));
    }

    #[test]
    fn test_resize_terminal_max_cols() {
        let agent_id = Uuid::new_v4();
        let msg = ClientMessage::resize_terminal(agent_id, MAX_TERMINAL_COLS + 1, 24);
        let result = msg.validate();
        assert!(result.is_err());
    }

    #[test]
    fn test_kill_agent_invalid_signal() {
        let agent_id = Uuid::new_v4();
        let msg = ClientMessage::KillAgent {
            agent_id,
            signal: Some(100),
        };
        let result = msg.validate();
        assert!(result.is_err());
        assert!(result
            .unwrap_err()
            .to_string()
            .contains("not a valid Unix signal"));
    }

    #[test]
    fn test_agent_input_max_length() {
        let agent_id = Uuid::new_v4();
        let large_input = "x".repeat(MAX_INPUT_LENGTH + 1);
        let msg = ClientMessage::agent_input(agent_id, large_input);
        let result = msg.validate();
        assert!(result.is_err());
        assert!(result
            .unwrap_err()
            .to_string()
            .contains("exceeds maximum length"));
    }

    #[test]
    fn test_valid_messages_pass_validation() {
        let agent_id = Uuid::new_v4();

        // All these should validate successfully
        assert!(ClientMessage::ping(1).validate().is_ok());
        assert!(ClientMessage::spawn_agent("/valid/path").validate().is_ok());
        assert!(ClientMessage::agent_input(agent_id, "hello")
            .validate()
            .is_ok());
        assert!(ClientMessage::kill_agent(agent_id).validate().is_ok());
        assert!(ClientMessage::resize_terminal(agent_id, 80, 24)
            .validate()
            .is_ok());
        assert!(ClientMessage::ListAgents.validate().is_ok());
    }

    // -------------------------------------------------------------------------
    // Error Conversion Tests
    // -------------------------------------------------------------------------

    #[test]
    fn test_protocol_error_to_server_message() {
        let err = ProtocolError::ValidationError("test error".to_string());
        let msg: ServerMessage = err.into();

        match msg {
            ServerMessage::Error { message, code, .. } => {
                assert!(message.contains("test error"));
                assert_eq!(code, Some(ErrorCode::InvalidMessage));
            }
            _ => panic!("Expected Error message"),
        }
    }

    // -------------------------------------------------------------------------
    // JSON Compatibility Tests
    // -------------------------------------------------------------------------

    #[test]
    fn test_parse_minimal_spawn_agent() {
        // Test that we can parse a minimal spawn_agent without optional fields
        let json = r#"{"type": "spawn_agent", "project_path": "/test"}"#;
        let msg: ClientMessage = serde_json::from_str(json).unwrap();
        match msg {
            ClientMessage::SpawnAgent {
                project_path,
                preset,
                cols,
                rows,
            } => {
                assert_eq!(project_path, "/test");
                assert!(preset.is_none());
                assert!(cols.is_none());
                assert!(rows.is_none());
            }
            _ => panic!("Expected SpawnAgent"),
        }
    }

    #[test]
    fn test_parse_full_spawn_agent() {
        // Test that we can parse a full spawn_agent with all fields
        let json = r#"{"type": "spawn_agent", "project_path": "/test", "preset": "dev", "cols": 120, "rows": 40}"#;
        let msg: ClientMessage = serde_json::from_str(json).unwrap();
        match msg {
            ClientMessage::SpawnAgent {
                project_path,
                preset,
                cols,
                rows,
            } => {
                assert_eq!(project_path, "/test");
                assert_eq!(preset, Some("dev".to_string()));
                assert_eq!(cols, Some(120));
                assert_eq!(rows, Some(40));
            }
            _ => panic!("Expected SpawnAgent"),
        }
    }
}
