//! WebSocket server implementation
//!
//! Provides a WebSocket server that listens on a configurable port and handles
//! connections from Godot clients.

use std::net::SocketAddr;
use std::path::Path;
use std::sync::Arc;

use futures_util::{SinkExt, StreamExt};
use tokio::net::{TcpListener, TcpStream};
use tokio::sync::broadcast;
use tokio_tungstenite::{accept_async, tungstenite::Message};
use tracing::{debug, error, info, warn};

use super::protocol::{
    ClientEnvelope, ClientMessage, ErrorCode, ServerMessage, DEFAULT_TERMINAL_COLS, DEFAULT_TERMINAL_ROWS,
};
use crate::agent::{AgentManager, SpawnConfig};
use crate::config::ProjectConfig;

/// Configuration for the WebSocket server
#[derive(Debug, Clone)]
pub struct ServerConfig {
    /// Address to bind to
    pub bind: String,
    /// Port to listen on
    pub port: u16,
    /// Optional authentication token
    pub token: Option<String>,
}

impl ServerConfig {
    /// Create a new server configuration
    pub fn new(bind: String, port: u16) -> Self {
        Self {
            bind,
            port,
            token: None,
        }
    }

    /// Set the authentication token
    pub fn with_token(mut self, token: Option<String>) -> Self {
        self.token = token;
        self
    }

    /// Get the socket address to bind to
    pub fn socket_addr(&self) -> String {
        format!("{}:{}", self.bind, self.port)
    }
}

/// WebSocket server for handling Godot client connections
pub struct WebSocketServer {
    config: ServerConfig,
    agent_manager: Arc<AgentManager>,
    shutdown_tx: broadcast::Sender<()>,
}

impl WebSocketServer {
    /// Create a new WebSocket server
    pub fn new(config: ServerConfig) -> Self {
        let (shutdown_tx, _) = broadcast::channel(1);
        Self {
            config,
            agent_manager: Arc::new(AgentManager::new()),
            shutdown_tx,
        }
    }

    /// Get a shutdown signal receiver (for external components to listen for shutdown)
    #[allow(dead_code)]
    pub fn shutdown_signal(&self) -> broadcast::Receiver<()> {
        self.shutdown_tx.subscribe()
    }

    /// Trigger server shutdown
    pub fn shutdown(&self) {
        let _ = self.shutdown_tx.send(());
    }

    /// Run the WebSocket server
    ///
    /// This will listen for incoming connections and handle them concurrently.
    /// The server will shut down gracefully when a shutdown signal is received.
    pub async fn run(&self) -> anyhow::Result<()> {
        let addr = self.config.socket_addr();
        let listener = TcpListener::bind(&addr).await?;
        info!("WebSocket server listening on ws://{}/ws", addr);

        let mut shutdown_rx = self.shutdown_tx.subscribe();

        loop {
            tokio::select! {
                // Accept new connections
                result = listener.accept() => {
                    match result {
                        Ok((stream, peer_addr)) => {
                            let agent_manager = Arc::clone(&self.agent_manager);
                            let shutdown_rx = self.shutdown_tx.subscribe();
                            let token = self.config.token.clone();

                            tokio::spawn(async move {
                                if let Err(e) = handle_connection(stream, peer_addr, agent_manager, shutdown_rx, token).await {
                                    error!("Connection error from {}: {}", peer_addr, e);
                                }
                            });
                        }
                        Err(e) => {
                            error!("Failed to accept connection: {}", e);
                        }
                    }
                }
                // Handle shutdown signal
                _ = shutdown_rx.recv() => {
                    info!("Shutdown signal received, stopping server");
                    break;
                }
            }
        }

        // Wait for active connections to finish
        let session_count = self.agent_manager.session_count().await;
        if session_count > 0 {
            info!("Waiting for {} active sessions to close...", session_count);
        }

        Ok(())
    }
}

/// Handle a single WebSocket connection
async fn handle_connection(
    stream: TcpStream,
    peer_addr: SocketAddr,
    agent_manager: Arc<AgentManager>,
    mut shutdown_rx: broadcast::Receiver<()>,
    token: Option<String>,
) -> anyhow::Result<()> {
    use crate::agent::AgentEvent;

    info!("New connection from {}", peer_addr);

    // Upgrade to WebSocket
    let ws_stream = accept_async(stream).await?;
    let (mut ws_sender, mut ws_receiver) = ws_stream.split();

    // Send welcome message, indicating if auth is required
    let welcome = if token.is_some() {
        ServerMessage::welcome_auth_required()
    } else {
        ServerMessage::welcome()
    };
    let welcome_json = serde_json::to_string(&welcome)?;
    ws_sender.send(Message::Text(welcome_json)).await?;
    debug!("Sent welcome message to {}", peer_addr);

    // Handle authentication if token is required
    if let Some(ref expected_token) = token {
        debug!("Waiting for authentication from {}", peer_addr);

        // Wait for the first message which should be authentication
        let auth_result = tokio::time::timeout(
            std::time::Duration::from_secs(30),
            wait_for_auth(&mut ws_receiver, expected_token),
        )
        .await;

        match auth_result {
            Ok(Ok(())) => {
                info!("Client {} authenticated successfully", peer_addr);
                let success = ServerMessage::auth_success();
                let success_json = serde_json::to_string(&success)?;
                ws_sender.send(Message::Text(success_json)).await?;
            }
            Ok(Err(e)) => {
                warn!("Authentication failed for {}: {}", peer_addr, e);
                let error = ServerMessage::error_with_code(e.to_string(), ErrorCode::AuthFailed);
                let error_json = serde_json::to_string(&error)?;
                ws_sender.send(Message::Text(error_json)).await?;
                let _ = ws_sender.send(Message::Close(None)).await;
                return Ok(());
            }
            Err(_) => {
                warn!("Authentication timeout for {}", peer_addr);
                let error =
                    ServerMessage::error_with_code("Authentication timeout", ErrorCode::AuthFailed);
                let error_json = serde_json::to_string(&error)?;
                ws_sender.send(Message::Text(error_json)).await?;
                let _ = ws_sender.send(Message::Close(None)).await;
                return Ok(());
            }
        }
    }

    // Subscribe to agent events
    let mut agent_event_rx = agent_manager.subscribe();

    // Message handling loop
    loop {
        tokio::select! {
            // Receive messages from client
            msg = ws_receiver.next() => {
                match msg {
                    Some(Ok(Message::Text(text))) => {
                        debug!("Received message from {}: {}", peer_addr, text);

                        match handle_message(&text, &agent_manager).await {
                            Ok(Some(response)) => {
                                let response_json = serde_json::to_string(&response)?;
                                ws_sender.send(Message::Text(response_json)).await?;
                            }
                            Ok(None) => {
                                // No response needed (e.g., agent input forwarded successfully)
                            }
                            Err(e) => {
                                let error_msg = ServerMessage::error_with_code(
                                    e.to_string(),
                                    ErrorCode::InternalError,
                                );
                                let error_json = serde_json::to_string(&error_msg)?;
                                ws_sender.send(Message::Text(error_json)).await?;
                            }
                        }
                    }
                    Some(Ok(Message::Binary(data))) => {
                        warn!("Received binary message from {} ({} bytes), ignoring", peer_addr, data.len());
                    }
                    Some(Ok(Message::Ping(data))) => {
                        ws_sender.send(Message::Pong(data)).await?;
                    }
                    Some(Ok(Message::Pong(_))) => {
                        // Ignore pong messages
                    }
                    Some(Ok(Message::Close(_))) => {
                        info!("Client {} requested close", peer_addr);
                        break;
                    }
                    Some(Ok(Message::Frame(_))) => {
                        // Raw frame, ignore
                    }
                    Some(Err(e)) => {
                        error!("WebSocket error from {}: {}", peer_addr, e);
                        break;
                    }
                    None => {
                        info!("Connection closed by {}", peer_addr);
                        break;
                    }
                }
            }
            // Forward agent events to client
            event = agent_event_rx.recv() => {
                match event {
                    Ok(AgentEvent::Output { agent_id, data }) => {
                        let output_str = String::from_utf8_lossy(&data).to_string();
                        let msg = ServerMessage::agent_output(agent_id, output_str);
                        let json = serde_json::to_string(&msg)?;
                        ws_sender.send(Message::Text(json)).await?;
                    }
                    Ok(AgentEvent::Exited { agent_id, exit_code, reason }) => {
                        let msg = ServerMessage::agent_exited_with_reason(agent_id, exit_code, reason);
                        let json = serde_json::to_string(&msg)?;
                        ws_sender.send(Message::Text(json)).await?;
                    }
                    Ok(AgentEvent::Resized { agent_id, cols, rows }) => {
                        let msg = ServerMessage::AgentResized { agent_id, cols, rows };
                        let json = serde_json::to_string(&msg)?;
                        ws_sender.send(Message::Text(json)).await?;
                    }
                    Ok(AgentEvent::Spawned { .. }) => {
                        // Spawn is handled by the direct response to SpawnAgent message
                    }
                    Err(broadcast::error::RecvError::Lagged(n)) => {
                        warn!("Client {} lagged by {} agent events", peer_addr, n);
                    }
                    Err(broadcast::error::RecvError::Closed) => {
                        info!("Agent event channel closed");
                        break;
                    }
                }
            }
            // Handle shutdown signal
            _ = shutdown_rx.recv() => {
                info!("Shutdown signal received, closing connection to {}", peer_addr);
                let _ = ws_sender.send(Message::Close(None)).await;
                break;
            }
        }
    }

    info!("Connection from {} closed", peer_addr);
    Ok(())
}

/// Handle a client message and return an optional response
///
/// Returns `Ok(None)` when no response is needed (e.g., agent input).
async fn handle_message(text: &str, agent_manager: &AgentManager) -> anyhow::Result<Option<ServerMessage>> {
    let envelope = ClientEnvelope::from_json(text).map_err(|e| {
        debug!("Invalid client message: {}", e);
        anyhow::anyhow!("{}", e)
    })?;
    let message = envelope.message;

    match message {
        ClientMessage::Authenticate { .. } => {
            warn!("Received unexpected Authenticate message after connection established");
            Ok(Some(ServerMessage::error_with_code(
                "Already authenticated",
                ErrorCode::InvalidMessage,
            )))
        }
        ClientMessage::Ping { seq } => {
            debug!("Received ping with seq {}", seq);
            Ok(Some(ServerMessage::Pong { seq }))
        }
        ClientMessage::SpawnAgent {
            project_path,
            preset,
            cols,
            rows,
        } => {
            debug!(
                "SpawnAgent request: project={}, preset={:?}",
                project_path, preset
            );

            // Validate project path exists
            let path = Path::new(&project_path);
            if !path.exists() {
                return Ok(Some(ServerMessage::error_with_code(
                    format!("Project path does not exist: {}", project_path),
                    ErrorCode::InvalidPath,
                )));
            }
            if !path.is_dir() {
                return Ok(Some(ServerMessage::error_with_code(
                    format!("Project path is not a directory: {}", project_path),
                    ErrorCode::InvalidPath,
                )));
            }

            // Load project config to get preset settings
            let project_config = ProjectConfig::load(path).unwrap_or_default();

            // Build spawn config with preset args and initial prompt
            let mut spawn_config = SpawnConfig::new(&project_path).with_size(
                cols.unwrap_or(DEFAULT_TERMINAL_COLS),
                rows.unwrap_or(DEFAULT_TERMINAL_ROWS),
            );

            // Apply preset if specified
            if let Some(preset_name) = &preset {
                spawn_config = spawn_config.with_preset(preset_name.clone());

                if let Some(preset_config) = project_config.get_preset(preset_name) {
                    if !preset_config.args.is_empty() {
                        spawn_config = spawn_config.with_args(preset_config.args.clone());
                    }
                    if let Some(ref prompt) = preset_config.initial_prompt {
                        spawn_config = spawn_config.with_initial_prompt(prompt.as_str());
                    }
                }
            } else if let Some(default_preset) = project_config.default_preset() {
                spawn_config = spawn_config.with_preset(&default_preset.name);
                if !default_preset.args.is_empty() {
                    spawn_config = spawn_config.with_args(default_preset.args.clone());
                }
                if let Some(ref prompt) = default_preset.initial_prompt {
                    spawn_config = spawn_config.with_initial_prompt(prompt.as_str());
                }
            }

            match agent_manager.spawn_agent(spawn_config).await {
                Ok(agent_id) => {
                    info!("Agent spawned: {} for project {}", agent_id, project_path);
                    Ok(Some(ServerMessage::agent_spawned(
                        agent_id,
                        project_path,
                        cols.unwrap_or(DEFAULT_TERMINAL_COLS),
                        rows.unwrap_or(DEFAULT_TERMINAL_ROWS),
                    )))
                }
                Err(e) => {
                    error!("Failed to spawn agent: {}", e);
                    Ok(Some(ServerMessage::error_with_code(
                        format!("Failed to spawn agent: {}", e),
                        ErrorCode::SpawnFailed,
                    )))
                }
            }
        }
        ClientMessage::AgentInput { agent_id, input } => {
            debug!(
                "AgentInput request: agent={}, input_len={}",
                agent_id,
                input.len()
            );
            match agent_manager.send_input(agent_id, &input).await {
                Ok(()) => Ok(None),
                Err(e) => Ok(Some(ServerMessage::agent_error(
                    agent_id,
                    format!("Failed to send input: {}", e),
                    ErrorCode::InternalError,
                ))),
            }
        }
        ClientMessage::KillAgent { agent_id, signal, .. } => {
            // Note: `signal` is accepted by the protocol but not forwarded to the PTY layer
            // because portable-pty only supports kill(), not arbitrary signal delivery.
            if signal.is_some() {
                debug!("KillAgent request: agent={} (signal={:?} ignored, using kill)", agent_id, signal);
            } else {
                debug!("KillAgent request: agent={}", agent_id);
            }
            match agent_manager.kill_agent(agent_id).await {
                Ok(()) => {
                    info!("Agent killed: {}", agent_id);
                    Ok(Some(ServerMessage::agent_exited(agent_id, None)))
                }
                Err(e) => Ok(Some(ServerMessage::agent_error(
                    agent_id,
                    format!("Failed to kill agent: {}", e),
                    ErrorCode::InternalError,
                ))),
            }
        }
        ClientMessage::ResizeTerminal {
            agent_id,
            cols,
            rows,
        } => {
            debug!(
                "ResizeTerminal request: agent={}, cols={}, rows={}",
                agent_id, cols, rows
            );
            match agent_manager.resize_agent(agent_id, cols, rows).await {
                Ok(()) => Ok(Some(ServerMessage::AgentResized {
                    agent_id,
                    cols,
                    rows,
                })),
                Err(e) => Ok(Some(ServerMessage::agent_error(
                    agent_id,
                    format!("Failed to resize terminal: {}", e),
                    ErrorCode::InternalError,
                ))),
            }
        }
        ClientMessage::ListAgents => {
            debug!("ListAgents request");
            let agents = agent_manager.list_agents().await;
            Ok(Some(ServerMessage::AgentList { agents }))
        }
        ClientMessage::GetAgentStatus { agent_id } => {
            debug!("GetAgentStatus request: agent={}", agent_id);
            match agent_manager.get_agent_status(agent_id).await {
                Ok(info) => Ok(Some(ServerMessage::AgentStatus {
                    agent_id: info.agent_id,
                    status: info.status,
                    project_path: info.project_path,
                    cols: info.cols,
                    rows: info.rows,
                })),
                Err(_) => Ok(Some(ServerMessage::agent_error(
                    agent_id,
                    "Agent not found",
                    ErrorCode::AgentNotFound,
                ))),
            }
        }
    }
}

/// Wait for an authentication message from the client
async fn wait_for_auth(
    ws_receiver: &mut futures_util::stream::SplitStream<
        tokio_tungstenite::WebSocketStream<TcpStream>,
    >,
    expected_token: &str,
) -> anyhow::Result<()> {
    use anyhow::anyhow;

    while let Some(msg) = ws_receiver.next().await {
        match msg {
            Ok(Message::Text(text)) => {
                let message: ClientMessage = serde_json::from_str(&text)?;
                match message {
                    ClientMessage::Authenticate { token } => {
                        if token == expected_token {
                            return Ok(());
                        } else {
                            return Err(anyhow!("Invalid authentication token"));
                        }
                    }
                    _ => {
                        return Err(anyhow!("Authentication required before other messages"));
                    }
                }
            }
            Ok(Message::Ping(data)) => {
                // Pings are OK during auth wait, but we can't respond here
                // Just continue waiting
                debug!("Received ping during auth wait: {:?}", data);
            }
            Ok(Message::Close(_)) => {
                return Err(anyhow!("Connection closed during authentication"));
            }
            Err(e) => {
                return Err(anyhow!("WebSocket error during authentication: {}", e));
            }
            _ => {
                // Ignore other message types during auth
            }
        }
    }

    Err(anyhow!("Connection closed before authentication"))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_server_config() {
        let config = ServerConfig::new("127.0.0.1".to_string(), 9000);
        assert_eq!(config.socket_addr(), "127.0.0.1:9000");
    }

    #[test]
    fn test_server_config_with_token() {
        let config =
            ServerConfig::new("0.0.0.0".to_string(), 8080).with_token(Some("secret".to_string()));
        assert_eq!(config.token, Some("secret".to_string()));
    }

    #[tokio::test]
    async fn test_handle_ping_message() {
        let agent_manager = AgentManager::new();
        let msg = r#"{"type": "ping", "seq": 42}"#;
        let response = handle_message(msg, &agent_manager).await.unwrap();

        match response {
            Some(ServerMessage::Pong { seq }) => assert_eq!(seq, 42),
            _ => panic!("Expected Some(Pong) response"),
        }
    }
}
