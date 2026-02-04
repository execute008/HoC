//! Halls of Creation Bridge Server
//!
//! WebSocket bridge for VR agent orchestration. Manages PTY sessions for Claude Code
//! agents and streams output to Godot clients over WebSocket.

mod agent;
mod config;
mod git;
mod pty;
mod server;

use std::sync::Arc;

use clap::Parser;
use tokio::signal;
use tracing::{info, Level};
use tracing_subscriber::FmtSubscriber;

use server::{ServerConfig, WebSocketServer};

/// Halls of Creation Bridge Server
///
/// WebSocket bridge for VR agent orchestration
#[derive(Parser, Debug)]
#[command(name = "hoc-bridge")]
#[command(version, about, long_about = None)]
struct Args {
    /// Port to listen on
    #[arg(short, long, default_value_t = 9000)]
    port: u16,

    /// Enable verbose logging
    #[arg(short, long)]
    verbose: bool,

    /// Authentication token for remote connections
    #[arg(long)]
    token: Option<String>,

    /// Bind address
    #[arg(long, default_value = "127.0.0.1")]
    bind: String,
}

#[tokio::main]
async fn main() -> anyhow::Result<()> {
    let args = Args::parse();

    // Initialize logging
    let log_level = if args.verbose {
        Level::DEBUG
    } else {
        Level::INFO
    };

    FmtSubscriber::builder()
        .with_max_level(log_level)
        .with_target(false)
        .compact()
        .init();

    info!("Halls of Creation Bridge v{}", env!("CARGO_PKG_VERSION"));

    if args.token.is_some() {
        info!("Token authentication enabled");
    }

    // Create server configuration
    let config = ServerConfig::new(args.bind, args.port).with_token(args.token);

    // Create and start the WebSocket server
    let server = Arc::new(WebSocketServer::new(config));
    let server_handle = Arc::clone(&server);

    // Spawn shutdown signal handler
    tokio::spawn(async move {
        shutdown_signal().await;
        info!("Initiating graceful shutdown...");
        server_handle.shutdown();
    });

    // Run the server
    server.run().await?;

    info!("Server shutdown complete");
    Ok(())
}

/// Wait for shutdown signal (SIGTERM or SIGINT)
async fn shutdown_signal() {
    let ctrl_c = async {
        signal::ctrl_c()
            .await
            .expect("Failed to install Ctrl+C handler");
    };

    #[cfg(unix)]
    let terminate = async {
        signal::unix::signal(signal::unix::SignalKind::terminate())
            .expect("Failed to install SIGTERM handler")
            .recv()
            .await;
    };

    #[cfg(not(unix))]
    let terminate = std::future::pending::<()>();

    tokio::select! {
        _ = ctrl_c => {
            info!("Received SIGINT (Ctrl+C)");
        }
        _ = terminate => {
            info!("Received SIGTERM");
        }
    }
}
