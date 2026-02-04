//! PTY process management
//!
//! Handles spawning processes with PTY terminal emulation, including:
//! - Configurable terminal size
//! - Stdin/stdout streaming
//! - Terminal resize support
//! - Proper cleanup on exit

#![allow(dead_code)]

use portable_pty::{native_pty_system, CommandBuilder, MasterPty, PtySize};
use std::collections::HashMap;
use std::io::{Read, Write};
use std::path::Path;
use std::sync::Arc;
use thiserror::Error;
use tokio::sync::{broadcast, mpsc, Mutex, RwLock};
use uuid::Uuid;

/// Errors that can occur during PTY operations
#[derive(Error, Debug)]
pub enum PtyError {
    #[error("Failed to open PTY: {0}")]
    OpenFailed(String),

    #[error("Failed to spawn process: {0}")]
    SpawnFailed(String),

    #[error("Failed to write to PTY: {0}")]
    WriteFailed(String),

    #[error("Failed to read from PTY: {0}")]
    ReadFailed(String),

    #[error("Failed to resize PTY: {0}")]
    ResizeFailed(String),

    #[error("Process not found: {0}")]
    ProcessNotFound(Uuid),

    #[error("Process already exited")]
    ProcessExited,

    #[error("PTY system error: {0}")]
    SystemError(String),
}

/// Result type for PTY operations
pub type PtyResult<T> = Result<T, PtyError>;

/// Terminal size configuration
#[derive(Debug, Clone, Copy)]
pub struct TerminalSize {
    pub cols: u16,
    pub rows: u16,
}

impl Default for TerminalSize {
    fn default() -> Self {
        Self { cols: 80, rows: 24 }
    }
}

impl TerminalSize {
    /// Create a new terminal size
    pub fn new(cols: u16, rows: u16) -> Self {
        Self { cols, rows }
    }

    /// Convert to portable-pty PtySize
    fn to_pty_size(self) -> PtySize {
        PtySize {
            rows: self.rows,
            cols: self.cols,
            pixel_width: 0,
            pixel_height: 0,
        }
    }
}

/// Output data from the PTY
#[derive(Debug, Clone)]
pub struct PtyOutput {
    /// The output data
    pub data: Vec<u8>,
}

/// Event emitted when a process exits
#[derive(Debug, Clone)]
pub struct ProcessExit {
    /// The process ID
    pub id: Uuid,
    /// Exit code if available
    pub exit_code: Option<i32>,
    /// Exit reason
    pub reason: ExitReason,
}

/// Reason for process exit
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ExitReason {
    /// Process exited normally
    Normal,
    /// Process was killed by signal
    Signal,
    /// Process was killed by request
    Killed,
    /// Unknown exit reason
    Unknown,
}

/// Handle to a running PTY process
pub struct PtyProcess {
    /// Unique identifier
    id: Uuid,
    /// The master PTY handle
    master: Arc<Mutex<Box<dyn MasterPty + Send>>>,
    /// Current terminal size
    size: Arc<RwLock<TerminalSize>>,
    /// Writer for sending input
    writer: Arc<Mutex<Box<dyn Write + Send>>>,
    /// Channel for receiving output
    output_rx: mpsc::Receiver<PtyOutput>,
    /// Channel for signaling shutdown
    shutdown_tx: broadcast::Sender<()>,
    /// Flag indicating if process has exited
    exited: Arc<RwLock<bool>>,
    /// Exit information
    exit_info: Arc<RwLock<Option<ProcessExit>>>,
}

impl PtyProcess {
    /// Spawn a new process with PTY
    ///
    /// # Arguments
    /// * `command` - The command to run
    /// * `args` - Command arguments
    /// * `working_dir` - Working directory for the process
    /// * `env` - Environment variables (optional)
    /// * `size` - Initial terminal size
    ///
    /// # Returns
    /// A new `PtyProcess` handle
    pub fn spawn(
        command: &str,
        args: &[String],
        working_dir: &Path,
        env: Option<&HashMap<String, String>>,
        size: TerminalSize,
    ) -> PtyResult<Self> {
        let id = Uuid::new_v4();

        // Get the native PTY system
        let pty_system = native_pty_system();

        // Open a new PTY with the specified size
        let pair = pty_system
            .openpty(size.to_pty_size())
            .map_err(|e| PtyError::OpenFailed(e.to_string()))?;

        // Build the command
        let mut cmd = CommandBuilder::new(command);
        cmd.args(args);
        cmd.cwd(working_dir);

        // Set environment variables if provided
        if let Some(env_vars) = env {
            for (key, value) in env_vars {
                cmd.env(key, value);
            }
        }

        // Spawn the process
        let _child = pair
            .slave
            .spawn_command(cmd)
            .map_err(|e| PtyError::SpawnFailed(e.to_string()))?;

        // Drop the slave - we only need the master
        drop(pair.slave);

        // Get reader and writer from the master
        let reader = pair
            .master
            .try_clone_reader()
            .map_err(|e| PtyError::SystemError(e.to_string()))?;
        let writer = pair
            .master
            .take_writer()
            .map_err(|e| PtyError::SystemError(e.to_string()))?;

        // Create channels
        let (output_tx, output_rx) = mpsc::channel(1024);
        let (shutdown_tx, _) = broadcast::channel(1);

        let exited = Arc::new(RwLock::new(false));
        let exit_info = Arc::new(RwLock::new(None));

        // Spawn the reader task
        let exited_clone = Arc::clone(&exited);
        let exit_info_clone = Arc::clone(&exit_info);
        let shutdown_rx = shutdown_tx.subscribe();
        let id_clone = id;

        std::thread::spawn(move || {
            Self::reader_loop(
                reader,
                output_tx,
                shutdown_rx,
                exited_clone,
                exit_info_clone,
                id_clone,
            );
        });

        Ok(Self {
            id,
            master: Arc::new(Mutex::new(pair.master)),
            size: Arc::new(RwLock::new(size)),
            writer: Arc::new(Mutex::new(writer)),
            output_rx,
            shutdown_tx,
            exited,
            exit_info,
        })
    }

    /// Reader loop that runs in a separate thread
    fn reader_loop(
        mut reader: Box<dyn Read + Send>,
        output_tx: mpsc::Sender<PtyOutput>,
        mut shutdown_rx: broadcast::Receiver<()>,
        exited: Arc<RwLock<bool>>,
        exit_info: Arc<RwLock<Option<ProcessExit>>>,
        id: Uuid,
    ) {
        let mut buffer = [0u8; 4096];

        loop {
            // Check for shutdown signal (non-blocking)
            match shutdown_rx.try_recv() {
                Ok(_) | Err(broadcast::error::TryRecvError::Closed) => {
                    break;
                }
                Err(broadcast::error::TryRecvError::Empty) => {}
                Err(broadcast::error::TryRecvError::Lagged(_)) => {}
            }

            // Read from PTY with timeout-like behavior
            match reader.read(&mut buffer) {
                Ok(0) => {
                    // EOF - process has exited
                    let rt = tokio::runtime::Handle::try_current();
                    if let Ok(handle) = rt {
                        handle.block_on(async {
                            *exited.write().await = true;
                            *exit_info.write().await = Some(ProcessExit {
                                id,
                                exit_code: None,
                                reason: ExitReason::Normal,
                            });
                        });
                    }
                    break;
                }
                Ok(n) => {
                    let output = PtyOutput {
                        data: buffer[..n].to_vec(),
                    };
                    // Try to send output, ignore if receiver is dropped
                    if output_tx.blocking_send(output).is_err() {
                        break;
                    }
                }
                Err(e) => {
                    // Check if it's a "would block" error on Unix
                    if e.kind() == std::io::ErrorKind::WouldBlock {
                        std::thread::sleep(std::time::Duration::from_millis(10));
                        continue;
                    }
                    // Other errors indicate process exit or PTY closed
                    let rt = tokio::runtime::Handle::try_current();
                    if let Ok(handle) = rt {
                        handle.block_on(async {
                            *exited.write().await = true;
                            *exit_info.write().await = Some(ProcessExit {
                                id,
                                exit_code: None,
                                reason: ExitReason::Unknown,
                            });
                        });
                    }
                    break;
                }
            }
        }
    }

    /// Get the process ID
    pub fn id(&self) -> Uuid {
        self.id
    }

    /// Get the current terminal size
    pub async fn size(&self) -> TerminalSize {
        *self.size.read().await
    }

    /// Check if the process has exited
    pub async fn has_exited(&self) -> bool {
        *self.exited.read().await
    }

    /// Get exit information if process has exited
    pub async fn exit_info(&self) -> Option<ProcessExit> {
        self.exit_info.read().await.clone()
    }

    /// Write input to the PTY (stdin)
    pub async fn write(&self, data: &[u8]) -> PtyResult<()> {
        if self.has_exited().await {
            return Err(PtyError::ProcessExited);
        }

        let mut writer = self.writer.lock().await;
        writer
            .write_all(data)
            .map_err(|e| PtyError::WriteFailed(e.to_string()))?;
        writer
            .flush()
            .map_err(|e| PtyError::WriteFailed(e.to_string()))?;

        Ok(())
    }

    /// Write a string to the PTY
    pub async fn write_str(&self, s: &str) -> PtyResult<()> {
        self.write(s.as_bytes()).await
    }

    /// Receive output from the PTY
    ///
    /// Returns `None` if the process has exited and all output has been consumed
    pub async fn recv(&mut self) -> Option<PtyOutput> {
        self.output_rx.recv().await
    }

    /// Try to receive output without blocking
    pub fn try_recv(&mut self) -> Option<PtyOutput> {
        self.output_rx.try_recv().ok()
    }

    /// Resize the terminal
    pub async fn resize(&self, cols: u16, rows: u16) -> PtyResult<()> {
        if self.has_exited().await {
            return Err(PtyError::ProcessExited);
        }

        let new_size = TerminalSize::new(cols, rows);
        let master = self.master.lock().await;

        master
            .resize(new_size.to_pty_size())
            .map_err(|e| PtyError::ResizeFailed(e.to_string()))?;

        *self.size.write().await = new_size;

        Ok(())
    }

    /// Kill the process
    pub async fn kill(&self) -> PtyResult<()> {
        // Signal shutdown to the reader thread
        let _ = self.shutdown_tx.send(());

        // Mark as exited
        *self.exited.write().await = true;
        *self.exit_info.write().await = Some(ProcessExit {
            id: self.id,
            exit_code: None,
            reason: ExitReason::Killed,
        });

        Ok(())
    }
}

impl Drop for PtyProcess {
    fn drop(&mut self) {
        // Signal shutdown to reader thread
        let _ = self.shutdown_tx.send(());
    }
}

/// Callback type for output streaming
pub type OutputCallback = Box<dyn Fn(Uuid, &[u8]) + Send + Sync>;

/// Callback type for process exit
pub type ExitCallback = Box<dyn Fn(ProcessExit) + Send + Sync>;

/// PTY process with callback-based output streaming
pub struct PtyProcessWithCallbacks {
    /// The underlying PTY process
    process: Arc<Mutex<PtyProcess>>,
    /// Process ID
    id: Uuid,
    /// Terminal size
    size: Arc<RwLock<TerminalSize>>,
    /// Flag indicating if callbacks are running
    running: Arc<RwLock<bool>>,
    /// Shutdown signal
    shutdown_tx: broadcast::Sender<()>,
}

impl PtyProcessWithCallbacks {
    /// Spawn a new process with callback-based output streaming
    pub fn spawn<F, E>(
        command: &str,
        args: &[String],
        working_dir: &Path,
        env: Option<&HashMap<String, String>>,
        size: TerminalSize,
        output_callback: F,
        exit_callback: E,
    ) -> PtyResult<Self>
    where
        F: Fn(Uuid, &[u8]) + Send + Sync + 'static,
        E: Fn(ProcessExit) + Send + Sync + 'static,
    {
        let process = PtyProcess::spawn(command, args, working_dir, env, size)?;
        let id = process.id();
        let process_size = Arc::new(RwLock::new(size));

        let (shutdown_tx, mut shutdown_rx) = broadcast::channel(1);
        let running = Arc::new(RwLock::new(true));
        let running_clone = Arc::clone(&running);

        let process = Arc::new(Mutex::new(process));
        let process_clone = Arc::clone(&process);

        // Spawn the output forwarding task
        tokio::spawn(async move {
            loop {
                tokio::select! {
                    _ = shutdown_rx.recv() => {
                        break;
                    }
                    output = async {
                        let mut proc = process_clone.lock().await;
                        proc.recv().await
                    } => {
                        match output {
                            Some(out) => {
                                output_callback(id, &out.data);
                            }
                            None => {
                                // Process exited
                                let proc = process_clone.lock().await;
                                if let Some(exit_info) = proc.exit_info().await {
                                    exit_callback(exit_info);
                                } else {
                                    exit_callback(ProcessExit {
                                        id,
                                        exit_code: None,
                                        reason: ExitReason::Unknown,
                                    });
                                }
                                break;
                            }
                        }
                    }
                }
            }
            *running_clone.write().await = false;
        });

        Ok(Self {
            process,
            id,
            size: process_size,
            running,
            shutdown_tx,
        })
    }

    /// Get the process ID
    pub fn id(&self) -> Uuid {
        self.id
    }

    /// Get the current terminal size
    pub async fn size(&self) -> TerminalSize {
        *self.size.read().await
    }

    /// Check if the process is still running
    pub async fn is_running(&self) -> bool {
        *self.running.read().await
    }

    /// Check if the process has exited
    pub async fn has_exited(&self) -> bool {
        self.process.lock().await.has_exited().await
    }

    /// Write input to the process
    pub async fn write(&self, data: &[u8]) -> PtyResult<()> {
        self.process.lock().await.write(data).await
    }

    /// Write a string to the process
    pub async fn write_str(&self, s: &str) -> PtyResult<()> {
        self.process.lock().await.write_str(s).await
    }

    /// Resize the terminal
    pub async fn resize(&self, cols: u16, rows: u16) -> PtyResult<()> {
        self.process.lock().await.resize(cols, rows).await?;
        *self.size.write().await = TerminalSize::new(cols, rows);
        Ok(())
    }

    /// Kill the process
    pub async fn kill(&self) -> PtyResult<()> {
        let _ = self.shutdown_tx.send(());
        self.process.lock().await.kill().await
    }
}

impl Drop for PtyProcessWithCallbacks {
    fn drop(&mut self) {
        let _ = self.shutdown_tx.send(());
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::time::Duration;
    use tokio::time::timeout;

    #[tokio::test]
    async fn test_terminal_size_default() {
        let size = TerminalSize::default();
        assert_eq!(size.cols, 80);
        assert_eq!(size.rows, 24);
    }

    #[tokio::test]
    async fn test_terminal_size_custom() {
        let size = TerminalSize::new(120, 40);
        assert_eq!(size.cols, 120);
        assert_eq!(size.rows, 40);
    }

    #[tokio::test]
    async fn test_spawn_process() {
        let process = PtyProcess::spawn(
            "echo",
            &["hello".to_string()],
            Path::new("/tmp"),
            None,
            TerminalSize::default(),
        );

        assert!(process.is_ok());
        let mut process = process.unwrap();

        // Wait for output with timeout
        let output = timeout(Duration::from_secs(2), process.recv()).await;
        assert!(output.is_ok());

        if let Ok(Some(output)) = output {
            let text = String::from_utf8_lossy(&output.data);
            assert!(text.contains("hello"));
        }
    }

    #[tokio::test]
    async fn test_process_write() {
        let process =
            PtyProcess::spawn("cat", &[], Path::new("/tmp"), None, TerminalSize::default());

        assert!(process.is_ok());
        let mut process = process.unwrap();

        // Write to the process
        let write_result = process.write_str("test input\n").await;
        assert!(write_result.is_ok());

        // Read the echoed output
        let output = timeout(Duration::from_secs(2), process.recv()).await;
        assert!(output.is_ok());
    }

    #[tokio::test]
    async fn test_process_resize() {
        let process =
            PtyProcess::spawn("cat", &[], Path::new("/tmp"), None, TerminalSize::default());

        assert!(process.is_ok());
        let process = process.unwrap();

        // Check initial size
        let size = process.size().await;
        assert_eq!(size.cols, 80);
        assert_eq!(size.rows, 24);

        // Resize
        let resize_result = process.resize(120, 40).await;
        assert!(resize_result.is_ok());

        // Check new size
        let size = process.size().await;
        assert_eq!(size.cols, 120);
        assert_eq!(size.rows, 40);
    }

    #[tokio::test]
    async fn test_process_kill() {
        let process =
            PtyProcess::spawn("cat", &[], Path::new("/tmp"), None, TerminalSize::default());

        assert!(process.is_ok());
        let process = process.unwrap();

        // Kill the process
        let kill_result = process.kill().await;
        assert!(kill_result.is_ok());

        // Should be marked as exited
        assert!(process.has_exited().await);
    }

    #[tokio::test]
    async fn test_exit_reason() {
        assert_eq!(ExitReason::Normal, ExitReason::Normal);
        assert_ne!(ExitReason::Normal, ExitReason::Killed);
    }

    #[tokio::test]
    async fn test_spawn_with_callbacks() {
        use std::sync::atomic::{AtomicBool, Ordering};

        let output_received = Arc::new(AtomicBool::new(false));
        let output_received_clone = Arc::clone(&output_received);

        let exit_received = Arc::new(AtomicBool::new(false));
        let exit_received_clone = Arc::clone(&exit_received);

        let process = PtyProcessWithCallbacks::spawn(
            "echo",
            &["callback test".to_string()],
            Path::new("/tmp"),
            None,
            TerminalSize::default(),
            move |_id, _data| {
                output_received_clone.store(true, Ordering::SeqCst);
            },
            move |_exit| {
                exit_received_clone.store(true, Ordering::SeqCst);
            },
        );

        assert!(process.is_ok());
        let process = process.unwrap();

        // Wait for output and exit
        tokio::time::sleep(Duration::from_millis(500)).await;

        assert!(output_received.load(Ordering::SeqCst));

        // Process should have exited (echo completes quickly)
        tokio::time::sleep(Duration::from_millis(500)).await;
        assert!(exit_received.load(Ordering::SeqCst));
    }

    #[tokio::test]
    async fn test_spawn_with_env() {
        let mut env = HashMap::new();
        env.insert("TEST_VAR".to_string(), "test_value".to_string());

        let process = PtyProcess::spawn(
            "sh",
            &["-c".to_string(), "echo $TEST_VAR".to_string()],
            Path::new("/tmp"),
            Some(&env),
            TerminalSize::default(),
        );

        assert!(process.is_ok());
        let mut process = process.unwrap();

        // Wait for output
        let output = timeout(Duration::from_secs(2), process.recv()).await;
        assert!(output.is_ok());

        if let Ok(Some(output)) = output {
            let text = String::from_utf8_lossy(&output.data);
            assert!(text.contains("test_value"));
        }
    }
}
