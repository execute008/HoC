//! Halls of Creation Bridge Server
//!
//! WebSocket bridge for VR agent orchestration. Manages PTY sessions for Claude Code
//! agents and streams output to Godot clients over WebSocket.

mod agent;
mod config;
mod git;
mod server;

use clap::Parser;
use tracing::{info, Level};
use tracing_subscriber::FmtSubscriber;

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

    info!(
        "Halls of Creation Bridge v{}",
        env!("CARGO_PKG_VERSION")
    );
    info!("Listening on {}:{}", args.bind, args.port);

    if args.token.is_some() {
        info!("Token authentication enabled");
    }

    // Server will be implemented in US-RBS-002
    info!("Bridge server initialized (WebSocket server pending US-RBS-002)");

    Ok(())
}
