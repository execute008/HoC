//! Agent manager for coordinating multiple sessions
//!
//! Maintains a registry of active agents and routes messages appropriately.

use std::collections::HashMap;
use std::sync::Arc;
use tokio::sync::RwLock;
use uuid::Uuid;

use super::AgentSession;

/// Manages all active agent sessions
pub struct AgentManager {
    /// Registry of active sessions
    sessions: Arc<RwLock<HashMap<Uuid, AgentSession>>>,
}

impl AgentManager {
    /// Create a new agent manager
    pub fn new() -> Self {
        Self {
            sessions: Arc::new(RwLock::new(HashMap::new())),
        }
    }

    /// Get the number of active sessions
    pub async fn session_count(&self) -> usize {
        self.sessions.read().await.len()
    }
}

impl Default for AgentManager {
    fn default() -> Self {
        Self::new()
    }
}
