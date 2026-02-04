//! Individual agent session
//!
//! Manages a single Claude Code agent with PTY terminal emulation.
//! Handles the full lifecycle: spawn, I/O routing, and cleanup.

#![allow(dead_code)]

use std::path::Path;
use std::sync::Arc;
use thiserror::Error;
use tokio::sync::{broadcast, RwLock};
use uuid::Uuid;

use crate::pty::{ExitReason, ProcessExit, PtyError, PtyProcess, TerminalSize};
use crate::server::AgentState;

/// Errors that can occur during agent session operations
#[derive(Debug, Error)]
pub enum SessionError {
    #[error("Failed to spawn agent: {0}")]
    SpawnFailed(String),

    #[error("Agent not running")]
    NotRunning,

    #[error("Agent already running")]
    AlreadyRunning,

    #[error("PTY error: {0}")]
    PtyError(#[from] PtyError),

    #[error("Invalid project path: {0}")]
    InvalidPath(String),

    #[error("Send error: {0}")]
    SendError(String),
}

/// Result type for session operations
pub type SessionResult<T> = Result<T, SessionError>;

/// Output data from the agent
#[derive(Debug, Clone)]
pub struct AgentOutput {
    /// The output data (may contain ANSI escape sequences)
    pub data: Vec<u8>,
}

/// Event when agent exits
#[derive(Debug, Clone)]
pub struct AgentExit {
    /// Agent session ID
    pub session_id: Uuid,
    /// Exit code if available
    pub exit_code: Option<i32>,
    /// Exit reason
    pub reason: ExitReason,
}

/// Configuration for spawning an agent
#[derive(Debug, Clone)]
pub struct SpawnConfig {
    /// Path to the project directory
    pub project_path: String,
    /// Terminal columns
    pub cols: u16,
    /// Terminal rows
    pub rows: u16,
    /// Optional preset name (unused currently, for future expansion)
    pub preset: Option<String>,
}

impl SpawnConfig {
    /// Create a new spawn config with default terminal size
    pub fn new(project_path: impl Into<String>) -> Self {
        Self {
            project_path: project_path.into(),
            cols: 80,
            rows: 24,
            preset: None,
        }
    }

    /// Set terminal dimensions
    pub fn with_size(mut self, cols: u16, rows: u16) -> Self {
        self.cols = cols;
        self.rows = rows;
        self
    }

    /// Set preset name
    pub fn with_preset(mut self, preset: impl Into<String>) -> Self {
        self.preset = Some(preset.into());
        self
    }
}

/// Represents a single agent session with full lifecycle management
pub struct AgentSession {
    /// Unique identifier for this session
    id: Uuid,
    /// Working directory for the agent
    project_path: String,
    /// Terminal dimensions
    cols: u16,
    rows: u16,
    /// Current state of the agent
    state: Arc<RwLock<AgentState>>,
    /// The PTY process (when running)
    process: Arc<RwLock<Option<PtyProcess>>>,
    /// Channel for sending output to subscribers
    output_tx: broadcast::Sender<AgentOutput>,
    /// Channel for signaling exit
    exit_tx: broadcast::Sender<AgentExit>,
    /// Shutdown signal
    shutdown_tx: broadcast::Sender<()>,
}

impl AgentSession {
    /// Create a new agent session (not yet spawned)
    pub fn new(project_path: impl Into<String>) -> Self {
        let (output_tx, _) = broadcast::channel(1024);
        let (exit_tx, _) = broadcast::channel(1);
        let (shutdown_tx, _) = broadcast::channel(1);

        Self {
            id: Uuid::new_v4(),
            project_path: project_path.into(),
            cols: 80,
            rows: 24,
            state: Arc::new(RwLock::new(AgentState::Stopped)),
            process: Arc::new(RwLock::new(None)),
            output_tx,
            exit_tx,
            shutdown_tx,
        }
    }

    /// Create a new agent session with specific configuration
    pub fn with_config(config: SpawnConfig) -> Self {
        let (output_tx, _) = broadcast::channel(1024);
        let (exit_tx, _) = broadcast::channel(1);
        let (shutdown_tx, _) = broadcast::channel(1);

        Self {
            id: Uuid::new_v4(),
            project_path: config.project_path,
            cols: config.cols,
            rows: config.rows,
            state: Arc::new(RwLock::new(AgentState::Stopped)),
            process: Arc::new(RwLock::new(None)),
            output_tx,
            exit_tx,
            shutdown_tx,
        }
    }

    /// Get the session ID
    pub fn id(&self) -> Uuid {
        self.id
    }

    /// Get the project path
    pub fn project_path(&self) -> &str {
        &self.project_path
    }

    /// Get terminal columns
    pub fn cols(&self) -> u16 {
        self.cols
    }

    /// Get terminal rows
    pub fn rows(&self) -> u16 {
        self.rows
    }

    /// Get the current state
    pub async fn state(&self) -> AgentState {
        *self.state.read().await
    }

    /// Subscribe to output events
    pub fn subscribe_output(&self) -> broadcast::Receiver<AgentOutput> {
        self.output_tx.subscribe()
    }

    /// Subscribe to exit events
    pub fn subscribe_exit(&self) -> broadcast::Receiver<AgentExit> {
        self.exit_tx.subscribe()
    }

    /// Spawn the claude command with PTY
    ///
    /// This starts the Claude Code agent in the specified project directory.
    pub async fn spawn(&self) -> SessionResult<()> {
        // Check if already running
        {
            let state = self.state.read().await;
            if *state == AgentState::Running || *state == AgentState::Starting {
                return Err(SessionError::AlreadyRunning);
            }
        }

        // Validate project path
        let project_path = Path::new(&self.project_path);
        if !project_path.exists() {
            return Err(SessionError::InvalidPath(format!(
                "Project path does not exist: {}",
                self.project_path
            )));
        }
        if !project_path.is_dir() {
            return Err(SessionError::InvalidPath(format!(
                "Project path is not a directory: {}",
                self.project_path
            )));
        }

        // Update state to starting
        *self.state.write().await = AgentState::Starting;

        // Spawn the claude command
        let size = TerminalSize::new(self.cols, self.rows);
        let process = PtyProcess::spawn(
            "claude",
            &[], // No args - claude will start in interactive mode
            project_path,
            None, // No additional env vars
            size,
        )
        .map_err(|e| SessionError::SpawnFailed(e.to_string()))?;

        // Store the process
        *self.process.write().await = Some(process);

        // Update state to running
        *self.state.write().await = AgentState::Running;

        // Start the output forwarding task
        self.start_output_forwarder().await;

        Ok(())
    }

    /// Start the background task that forwards PTY output to subscribers
    async fn start_output_forwarder(&self) {
        let process = Arc::clone(&self.process);
        let state: Arc<RwLock<AgentState>> = Arc::clone(&self.state);
        let output_tx = self.output_tx.clone();
        let exit_tx = self.exit_tx.clone();
        let session_id = self.id;
        let mut shutdown_rx = self.shutdown_tx.subscribe();

        tokio::spawn(async move {
            loop {
                tokio::select! {
                    // Check for shutdown signal
                    _ = shutdown_rx.recv() => {
                        break;
                    }
                    // Poll for output
                    _ = tokio::time::sleep(tokio::time::Duration::from_millis(10)) => {
                        let mut proc_guard = process.write().await;
                        if let Some(ref mut proc) = *proc_guard {
                            // Check for output
                            while let Some(output) = proc.try_recv() {
                                let _ = output_tx.send(AgentOutput { data: output.data });
                            }

                            // Check if process has exited
                            if proc.has_exited().await {
                                let exit_info = proc.exit_info().await;
                                let (exit_code, reason) = match exit_info {
                                    Some(info) => (info.exit_code, info.reason),
                                    None => (None, ExitReason::Unknown),
                                };

                                // Update state
                                *state.write().await = AgentState::Stopped;

                                // Send exit notification
                                let _ = exit_tx.send(AgentExit {
                                    session_id,
                                    exit_code,
                                    reason,
                                });

                                // Clear the process
                                *proc_guard = None;
                                break;
                            }
                        } else {
                            // No process, exit the loop
                            break;
                        }
                    }
                }
            }
        });
    }

    /// Write input to the agent's stdin
    pub async fn write_input(&self, input: &[u8]) -> SessionResult<()> {
        let proc_guard = self.process.read().await;
        if let Some(ref process) = *proc_guard {
            process.write(input).await.map_err(SessionError::PtyError)
        } else {
            Err(SessionError::NotRunning)
        }
    }

    /// Write a string to the agent's stdin
    pub async fn write_str(&self, input: &str) -> SessionResult<()> {
        self.write_input(input.as_bytes()).await
    }

    /// Resize the terminal
    pub async fn resize(&mut self, cols: u16, rows: u16) -> SessionResult<()> {
        let proc_guard = self.process.read().await;
        if let Some(ref process) = *proc_guard {
            process.resize(cols, rows).await.map_err(SessionError::PtyError)?;
            self.cols = cols;
            self.rows = rows;
            Ok(())
        } else {
            Err(SessionError::NotRunning)
        }
    }

    /// Kill the agent process
    pub async fn kill(&self) -> SessionResult<()> {
        // Update state to stopping
        *self.state.write().await = AgentState::Stopping;

        // Signal shutdown to the forwarder
        let _ = self.shutdown_tx.send(());

        // Kill the process
        let proc_guard = self.process.read().await;
        if let Some(ref process) = *proc_guard {
            process.kill().await.map_err(SessionError::PtyError)?;
        }

        Ok(())
    }

    /// Check if the agent is running
    pub async fn is_running(&self) -> bool {
        *self.state.read().await == AgentState::Running
    }

    /// Get exit information if the agent has exited
    pub async fn exit_info(&self) -> Option<ProcessExit> {
        let proc_guard = self.process.read().await;
        if let Some(ref process) = *proc_guard {
            process.exit_info().await
        } else {
            None
        }
    }
}

impl Drop for AgentSession {
    fn drop(&mut self) {
        // Signal shutdown
        let _ = self.shutdown_tx.send(());
    }
}

/// Handle for receiving agent output asynchronously
pub struct OutputReceiver {
    rx: broadcast::Receiver<AgentOutput>,
}

impl OutputReceiver {
    /// Create from a broadcast receiver
    pub fn new(rx: broadcast::Receiver<AgentOutput>) -> Self {
        Self { rx }
    }

    /// Receive the next output
    pub async fn recv(&mut self) -> Option<AgentOutput> {
        self.rx.recv().await.ok()
    }
}

/// Handle for receiving agent exit notification
pub struct ExitReceiver {
    rx: broadcast::Receiver<AgentExit>,
}

impl ExitReceiver {
    /// Create from a broadcast receiver
    pub fn new(rx: broadcast::Receiver<AgentExit>) -> Self {
        Self { rx }
    }

    /// Wait for the agent to exit
    pub async fn wait(&mut self) -> Option<AgentExit> {
        self.rx.recv().await.ok()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_spawn_config_new() {
        let config = SpawnConfig::new("/test/path");
        assert_eq!(config.project_path, "/test/path");
        assert_eq!(config.cols, 80);
        assert_eq!(config.rows, 24);
        assert!(config.preset.is_none());
    }

    #[test]
    fn test_spawn_config_with_size() {
        let config = SpawnConfig::new("/test/path").with_size(120, 40);
        assert_eq!(config.cols, 120);
        assert_eq!(config.rows, 40);
    }

    #[test]
    fn test_spawn_config_with_preset() {
        let config = SpawnConfig::new("/test/path").with_preset("code-review");
        assert_eq!(config.preset, Some("code-review".to_string()));
    }

    #[test]
    fn test_agent_session_new() {
        let session = AgentSession::new("/test/path");
        assert_eq!(session.project_path(), "/test/path");
        assert_eq!(session.cols(), 80);
        assert_eq!(session.rows(), 24);
    }

    #[test]
    fn test_agent_session_with_config() {
        let config = SpawnConfig::new("/test/path")
            .with_size(100, 50)
            .with_preset("test");
        let session = AgentSession::with_config(config);
        assert_eq!(session.project_path(), "/test/path");
        assert_eq!(session.cols(), 100);
        assert_eq!(session.rows(), 50);
    }

    #[tokio::test]
    async fn test_agent_session_initial_state() {
        let session = AgentSession::new("/test/path");
        assert_eq!(session.state().await, AgentState::Stopped);
        assert!(!session.is_running().await);
    }

    #[tokio::test]
    async fn test_spawn_invalid_path() {
        let session = AgentSession::new("/nonexistent/path/that/does/not/exist");
        let result = session.spawn().await;
        assert!(result.is_err());
        match result {
            Err(SessionError::InvalidPath(_)) => {}
            _ => panic!("Expected InvalidPath error"),
        }
    }

    #[tokio::test]
    async fn test_write_input_not_running() {
        let session = AgentSession::new("/tmp");
        let result = session.write_input(b"test").await;
        assert!(result.is_err());
        match result {
            Err(SessionError::NotRunning) => {}
            _ => panic!("Expected NotRunning error"),
        }
    }

    #[tokio::test]
    async fn test_subscribe_output() {
        let session = AgentSession::new("/tmp");
        let _rx = session.subscribe_output();
        // Just test that we can subscribe
    }

    #[tokio::test]
    async fn test_subscribe_exit() {
        let session = AgentSession::new("/tmp");
        let _rx = session.subscribe_exit();
        // Just test that we can subscribe
    }
}
