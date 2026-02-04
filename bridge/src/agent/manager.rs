//! Agent manager for coordinating multiple sessions
//!
//! Maintains a registry of active agents and routes messages appropriately.
//! Provides thread-safe access to agent sessions and handles lifecycle events.

#![allow(dead_code)]

use std::collections::HashMap;
use std::sync::Arc;
use thiserror::Error;
use tokio::sync::{broadcast, RwLock};
use tracing::{debug, info, warn};
use uuid::Uuid;

use super::{AgentSession, SessionError, SpawnConfig};
use crate::server::{AgentInfo, AgentState};

/// Errors that can occur during agent manager operations
#[derive(Debug, Error)]
pub enum ManagerError {
    #[error("Agent not found: {0}")]
    AgentNotFound(Uuid),

    #[error("Session error: {0}")]
    SessionError(#[from] SessionError),

    #[error("Failed to broadcast event: {0}")]
    BroadcastError(String),
}

/// Result type for manager operations
pub type ManagerResult<T> = Result<T, ManagerError>;

/// Event types broadcast by the agent manager
#[derive(Debug, Clone)]
pub enum AgentEvent {
    /// An agent was spawned
    Spawned {
        agent_id: Uuid,
        project_path: String,
        cols: u16,
        rows: u16,
    },
    /// An agent produced output
    Output { agent_id: Uuid, data: Vec<u8> },
    /// An agent exited
    Exited {
        agent_id: Uuid,
        exit_code: Option<i32>,
        reason: String,
    },
    /// An agent was resized
    Resized {
        agent_id: Uuid,
        cols: u16,
        rows: u16,
    },
}

/// Manages all active agent sessions
///
/// The AgentManager is the central coordinator for agent sessions. It:
/// - Maintains a thread-safe registry of active agents
/// - Routes messages to the correct agent by ID
/// - Handles spawn/kill requests
/// - Broadcasts agent events to subscribed clients
pub struct AgentManager {
    /// Registry of active sessions (thread-safe via RwLock)
    sessions: Arc<RwLock<HashMap<Uuid, AgentSession>>>,
    /// Channel for broadcasting agent events to subscribers
    event_tx: broadcast::Sender<AgentEvent>,
}

impl AgentManager {
    /// Create a new agent manager
    pub fn new() -> Self {
        let (event_tx, _) = broadcast::channel(1024);
        Self {
            sessions: Arc::new(RwLock::new(HashMap::new())),
            event_tx,
        }
    }

    /// Subscribe to agent events
    ///
    /// Returns a receiver that will receive all agent events (spawned, output, exited, etc.)
    pub fn subscribe(&self) -> broadcast::Receiver<AgentEvent> {
        self.event_tx.subscribe()
    }

    /// Get the number of active sessions
    pub async fn session_count(&self) -> usize {
        self.sessions.read().await.len()
    }

    /// Spawn a new agent session
    ///
    /// Creates a new agent with the given configuration, starts it, and adds it to the registry.
    /// Returns the agent ID on success.
    pub async fn spawn_agent(&self, config: SpawnConfig) -> ManagerResult<Uuid> {
        let project_path = config.project_path.clone();
        let cols = config.cols;
        let rows = config.rows;

        // Create the session
        let session = AgentSession::with_config(config);
        let agent_id = session.id();

        info!("Spawning agent {} for project: {}", agent_id, project_path);

        // Start the agent
        session.spawn().await?;

        // Set up output forwarding to broadcast channel
        self.setup_output_forwarding(agent_id, &session).await;

        // Add to registry
        {
            let mut sessions = self.sessions.write().await;
            sessions.insert(agent_id, session);
        }

        // Broadcast spawn event
        let _ = self.event_tx.send(AgentEvent::Spawned {
            agent_id,
            project_path,
            cols,
            rows,
        });

        debug!("Agent {} spawned successfully", agent_id);
        Ok(agent_id)
    }

    /// Set up forwarding from session output to manager broadcast channel
    async fn setup_output_forwarding(&self, agent_id: Uuid, session: &AgentSession) {
        let mut output_rx = session.subscribe_output();
        let mut exit_rx = session.subscribe_exit();
        let event_tx = self.event_tx.clone();
        let sessions = Arc::clone(&self.sessions);

        // Spawn task to forward output events
        tokio::spawn(async move {
            loop {
                tokio::select! {
                    // Forward output events
                    result = output_rx.recv() => {
                        match result {
                            Ok(output) => {
                                let _ = event_tx.send(AgentEvent::Output {
                                    agent_id,
                                    data: output.data,
                                });
                            }
                            Err(broadcast::error::RecvError::Closed) => {
                                break;
                            }
                            Err(broadcast::error::RecvError::Lagged(n)) => {
                                warn!("Agent {} output receiver lagged by {} messages", agent_id, n);
                            }
                        }
                    }
                    // Handle exit events
                    result = exit_rx.recv() => {
                        match result {
                            Ok(exit) => {
                                let reason = format!("{:?}", exit.reason);
                                let _ = event_tx.send(AgentEvent::Exited {
                                    agent_id,
                                    exit_code: exit.exit_code,
                                    reason,
                                });

                                // Remove from registry
                                let mut sessions_guard = sessions.write().await;
                                sessions_guard.remove(&agent_id);
                                info!("Agent {} removed from registry after exit", agent_id);
                                break;
                            }
                            Err(broadcast::error::RecvError::Closed) => {
                                break;
                            }
                            Err(broadcast::error::RecvError::Lagged(_)) => {
                                // Exit events shouldn't lag, but handle anyway
                            }
                        }
                    }
                }
            }
        });
    }

    /// Kill an agent session
    ///
    /// Terminates the agent and removes it from the registry.
    pub async fn kill_agent(&self, agent_id: Uuid) -> ManagerResult<()> {
        info!("Kill request for agent {}", agent_id);

        // Get the session (read lock first)
        let session_exists = {
            let sessions = self.sessions.read().await;
            sessions.contains_key(&agent_id)
        };

        if !session_exists {
            return Err(ManagerError::AgentNotFound(agent_id));
        }

        // Kill the session
        {
            let sessions = self.sessions.read().await;
            if let Some(session) = sessions.get(&agent_id) {
                session.kill().await?;
            }
        }

        // Note: The session will be removed from the registry by the exit handler
        // in setup_output_forwarding when the exit event is received

        debug!("Agent {} kill signal sent", agent_id);
        Ok(())
    }

    /// Send input to an agent
    ///
    /// Routes the input to the correct agent by ID.
    pub async fn send_input(&self, agent_id: Uuid, input: &str) -> ManagerResult<()> {
        let sessions = self.sessions.read().await;
        let session = sessions
            .get(&agent_id)
            .ok_or(ManagerError::AgentNotFound(agent_id))?;

        session.write_str(input).await?;
        debug!("Sent {} bytes to agent {}", input.len(), agent_id);
        Ok(())
    }

    /// Resize an agent's terminal
    ///
    /// Routes the resize request to the correct agent by ID.
    pub async fn resize_agent(&self, agent_id: Uuid, cols: u16, rows: u16) -> ManagerResult<()> {
        // We need write access to the session to resize (it modifies cols/rows)
        let mut sessions = self.sessions.write().await;
        let session = sessions
            .get_mut(&agent_id)
            .ok_or(ManagerError::AgentNotFound(agent_id))?;

        session.resize(cols, rows).await?;

        // Broadcast resize event
        let _ = self.event_tx.send(AgentEvent::Resized {
            agent_id,
            cols,
            rows,
        });

        debug!("Agent {} resized to {}x{}", agent_id, cols, rows);
        Ok(())
    }

    /// Get the status of a specific agent
    pub async fn get_agent_status(&self, agent_id: Uuid) -> ManagerResult<AgentInfo> {
        let sessions = self.sessions.read().await;
        let session = sessions
            .get(&agent_id)
            .ok_or(ManagerError::AgentNotFound(agent_id))?;

        Ok(AgentInfo {
            agent_id: session.id(),
            project_path: session.project_path().to_string(),
            status: session.state().await,
            cols: session.cols(),
            rows: session.rows(),
        })
    }

    /// List all active agents
    pub async fn list_agents(&self) -> Vec<AgentInfo> {
        let sessions = self.sessions.read().await;
        let mut agents = Vec::with_capacity(sessions.len());

        for session in sessions.values() {
            agents.push(AgentInfo {
                agent_id: session.id(),
                project_path: session.project_path().to_string(),
                status: session.state().await,
                cols: session.cols(),
                rows: session.rows(),
            });
        }

        agents
    }

    /// Check if an agent exists in the registry
    pub async fn agent_exists(&self, agent_id: Uuid) -> bool {
        self.sessions.read().await.contains_key(&agent_id)
    }

    /// Get the state of an agent
    pub async fn agent_state(&self, agent_id: Uuid) -> ManagerResult<AgentState> {
        let sessions = self.sessions.read().await;
        let session = sessions
            .get(&agent_id)
            .ok_or(ManagerError::AgentNotFound(agent_id))?;

        Ok(session.state().await)
    }

    /// Shutdown all agents
    ///
    /// Kills all active agent sessions. Used during server shutdown.
    pub async fn shutdown_all(&self) {
        info!("Shutting down all agents");
        let agent_ids: Vec<Uuid> = {
            let sessions = self.sessions.read().await;
            sessions.keys().copied().collect()
        };

        for agent_id in agent_ids {
            if let Err(e) = self.kill_agent(agent_id).await {
                warn!("Error killing agent {} during shutdown: {}", agent_id, e);
            }
        }
    }
}

impl Default for AgentManager {
    fn default() -> Self {
        Self::new()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[tokio::test]
    async fn test_manager_new() {
        let manager = AgentManager::new();
        assert_eq!(manager.session_count().await, 0);
    }

    #[tokio::test]
    async fn test_manager_subscribe() {
        let manager = AgentManager::new();
        let _rx = manager.subscribe();
        // Just test that we can subscribe
    }

    #[tokio::test]
    async fn test_agent_not_found() {
        let manager = AgentManager::new();
        let fake_id = Uuid::new_v4();

        let result = manager.send_input(fake_id, "test").await;
        assert!(matches!(result, Err(ManagerError::AgentNotFound(_))));

        let result = manager.kill_agent(fake_id).await;
        assert!(matches!(result, Err(ManagerError::AgentNotFound(_))));

        let result = manager.get_agent_status(fake_id).await;
        assert!(matches!(result, Err(ManagerError::AgentNotFound(_))));
    }

    #[tokio::test]
    async fn test_agent_exists() {
        let manager = AgentManager::new();
        let fake_id = Uuid::new_v4();
        assert!(!manager.agent_exists(fake_id).await);
    }

    #[tokio::test]
    async fn test_list_agents_empty() {
        let manager = AgentManager::new();
        let agents = manager.list_agents().await;
        assert!(agents.is_empty());
    }

    #[tokio::test]
    async fn test_spawn_invalid_path() {
        let manager = AgentManager::new();
        let config = SpawnConfig::new("/nonexistent/path/that/does/not/exist");
        let result = manager.spawn_agent(config).await;
        assert!(result.is_err());
        // Session count should still be 0 since spawn failed
        assert_eq!(manager.session_count().await, 0);
    }

    #[tokio::test]
    async fn test_manager_default() {
        let manager = AgentManager::default();
        assert_eq!(manager.session_count().await, 0);
    }
}
