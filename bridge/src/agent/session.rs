//! Individual agent session
//!
//! Manages a single Claude Code agent with PTY terminal emulation.

use uuid::Uuid;

/// Represents a single agent session
pub struct AgentSession {
    /// Unique identifier for this session
    pub id: Uuid,
    /// Working directory for the agent
    pub project_path: String,
    /// Terminal dimensions
    pub cols: u16,
    pub rows: u16,
    // PTY and process handles will be added in US-RBS-004/005
}

impl AgentSession {
    /// Create a new agent session (not yet spawned)
    pub fn new(project_path: String) -> Self {
        Self {
            id: Uuid::new_v4(),
            project_path,
            cols: 80,
            rows: 24,
        }
    }

    /// Get the session ID
    pub fn id(&self) -> Uuid {
        self.id
    }
}
