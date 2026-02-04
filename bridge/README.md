# Halls of Creation Bridge Server

WebSocket bridge server for VR agent orchestration. Manages PTY sessions for Claude Code agents and streams output to Godot clients.

## Requirements

- Rust 1.75+ (for edition 2021 features)
- OpenSSL development libraries (for git2)
- pkg-config (macOS/Linux)

### macOS

```bash
brew install openssl pkg-config
```

### Ubuntu/Debian

```bash
sudo apt-get install libssl-dev pkg-config
```

## Building

```bash
# Development build
cargo build

# Release build (optimized)
cargo build --release
```

## Running

```bash
# Run with default settings (port 9000)
cargo run

# Run with custom port
cargo run -- --port 8080

# Run with verbose logging
cargo run -- --verbose

# Run with authentication token
cargo run -- --token your-secret-token

# Run bound to all interfaces (for remote connections)
cargo run -- --bind 0.0.0.0 --port 9000
```

## CLI Options

| Option | Short | Default | Description |
|--------|-------|---------|-------------|
| `--port` | `-p` | 9000 | Port to listen on |
| `--verbose` | `-v` | false | Enable debug logging |
| `--token` | | none | Authentication token for remote connections |
| `--bind` | | 127.0.0.1 | Bind address |

## Project Structure

```
bridge/
├── Cargo.toml
├── README.md
└── src/
    ├── main.rs          # Entry point and CLI
    ├── server/          # WebSocket server
    │   ├── mod.rs
    │   ├── handler.rs   # Connection handling
    │   └── protocol.rs  # Message definitions
    ├── agent/           # Agent session management
    │   ├── mod.rs
    │   ├── session.rs   # Individual agent session
    │   └── manager.rs   # Multi-agent coordinator
    ├── git/             # Git operations
    │   ├── mod.rs
    │   └── worktree.rs  # Worktree management
    └── config/          # Configuration
        ├── mod.rs
        └── project.rs   # Project config loading
```

## Development

```bash
# Type checking
cargo check

# Linting
cargo clippy

# Run tests
cargo test

# Format code
cargo fmt
```

## Protocol

The bridge uses JSON messages over WebSocket. See `src/server/protocol.rs` for message definitions.

### Client Messages

- `ping` - Keepalive ping
- `spawn_agent` - Request new agent session
- `agent_input` - Send input to agent
- `kill_agent` - Terminate agent
- `resize_terminal` - Resize agent terminal

### Server Messages

- `pong` - Keepalive response
- `welcome` - Initial connection with protocol version
- `agent_spawned` - Agent created successfully
- `agent_output` - Terminal output from agent
- `agent_exited` - Agent terminated
- `error` - Error occurred
