# PRD Compliance Check — Sweep Round 10

## Phase 1A: Godot XR Foundation

| Story | Status | Notes |
|-------|--------|-------|
| US-GXR-001: XR Scene Setup | ✅ | main.tscn has XROrigin3D, XRCamera3D, L/R controllers, PlayerBody, StartXR |
| US-GXR-002: Infinite Grid | ✅ | infinite_grid.tscn with shader, configurable fade/color/width |
| US-GXR-003: Environment | ✅ | environment.tscn with skybox, ambient lighting |
| US-GXR-004: Locomotion | ✅ | Teleport, smooth move, snap turn all configured in main.tscn |
| US-GXR-005: WorkspacePanel | ✅ | Grab, resize, title bar, close/minimize, billboard mode |
| US-GXR-006: Terminal Panel | ✅ | Monospace, ANSI colors, scrollback, controller scroll |
| US-GXR-007: ANSI Parser | ✅ | SGR, 16+bright+256+truecolor, bold/italic/underline, cursor, clear |
| US-GXR-008: Panel Spawning | ✅ | Controller menu, panel types, spawn distance, registry, close |

## Phase 1B: Rust Bridge Server

| Story | Status | Notes |
|-------|--------|-------|
| US-RBS-001: Project Setup | ✅ | Cargo.toml, compiles, module structure, CLI (clap), README |
| US-RBS-002: WebSocket Server | ✅ | Configurable port, /ws endpoint, concurrent connections, routing, graceful shutdown |
| US-RBS-003: Protocol Messages | ✅ | Structs, serde, validation, protocol version |
| US-RBS-004: PTY Management | ✅ | portable-pty, configurable size, stdout stream, stdin, resize, cleanup |
| US-RBS-005: Agent Session | ✅ | Lifecycle, spawn claude, route output, accept input, cleanup, exit code |
| US-RBS-006: Agent Manager | ✅ | Registry, routing, spawn/kill, broadcast, thread-safe (Arc<Mutex>) |
| US-RBS-007: Git Worktree | ✅ | Detect repo, list/create worktrees, metadata, error handling |
| US-RBS-008: Project Config | ✅ | config.toml, defaults, presets, workspace layout save/load |

## Phase 2: Integration

| Story | Status | Notes |
|-------|--------|-------|
| US-INT-001: Bridge Launcher | ✅ | Locates binary, auto-launch, port check, kill on exit, missing binary error |
| US-INT-002: WebSocket Client | ✅ | Connect, auto-reconnect, JSON send/parse, signals |
| US-INT-003: Agent Orchestrator | ✅ | Singleton, session management, spawn/kill, callbacks, signals |
| US-INT-004: Live Terminal | ✅ | Bind by ID, real-time output, ANSI rendered, scrollback, status indicator |
| US-INT-005: Input Routing | ✅ | Keyboard input routed, virtual keyboard stub, correct agent, Enter, Ctrl+C |
| US-INT-006: Spawn UI | ✅ | Recent projects, directory picker, presets, bound terminal, error feedback |

## Phase 3: Multi-Agent & Persistence

| Story | Status | Notes |
|-------|--------|-------|
| US-MAP-001: Multi-Agent | ✅ | Multiple simultaneous, unique IDs, correct routing, individual kill, resource limits |
| US-MAP-002: Agent Overview | ✅ | Agent list panel with status, focus/stop/restart actions, working dir, real-time |
| US-MAP-003: Worktree UI | ✅ | List worktrees, create with branch input, select as working dir, error handling |
| US-MAP-004: Layout Persistence | ✅ | Save/restore via LayoutManager + .hoc/workspace.json |

## Phase 4: Quest & Remote

| Story | Status | Notes |
|-------|--------|-------|
| US-QRM-001: Quest Export | ⚠️ | OpenXR vendors configured, hand tracking enabled. Export preset likely needs manual setup |
| US-QRM-002: Performance | ✅ | PerformanceManager with LOD, throttling, memory monitoring |
| US-QRM-003: Remote Bridge | ✅ | Settings UI for IP/port, WiFi connection, status indicator, auto-reconnect |
| US-QRM-004: Auth Token | ✅ | --token CLI, rejection without token, hint display, stored in ProjectConfig |

## Gaps Found

1. **AgentState lacks IDLE/ERROR** — PRD US-MAP-002 wants "running, idle, error" but only SPAWNING/RUNNING/EXITING/EXITED exist. Would need bridge-side heartbeat detection to distinguish running vs idle.
2. **Quest export preset** — Not automated; requires manual Godot editor setup for APK export signing.
3. **Virtual keyboard** — Stub exists in InputRouter but no actual VR keyboard UI implemented (marked optional in PRD).
