//! Project configuration
//!
//! Loads project-specific configuration from .hoc/config.toml

use serde::{Deserialize, Serialize};
use std::path::Path;
use thiserror::Error;

/// Configuration file name
pub const CONFIG_DIR: &str = ".hoc";
pub const CONFIG_FILE: &str = "config.toml";
pub const WORKSPACE_FILE: &str = "workspace.json";

/// Errors that can occur during config operations
#[derive(Error, Debug)]
pub enum ConfigError {
    #[error("Failed to read config file: {0}")]
    Read(#[from] std::io::Error),
    #[error("Failed to parse config: {0}")]
    Parse(#[from] toml::de::Error),
    #[error("Failed to serialize config: {0}")]
    Serialize(#[from] toml::ser::Error),
}

/// Agent preset configuration
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct AgentPreset {
    /// Name of the preset
    pub name: String,
    /// Additional command line arguments
    #[serde(default)]
    pub args: Vec<String>,
    /// Initial prompt to send to agent
    pub initial_prompt: Option<String>,
}

/// Project configuration
#[derive(Debug, Clone, Serialize, Deserialize, Default)]
pub struct ProjectConfig {
    /// Agent presets
    #[serde(default)]
    pub presets: Vec<AgentPreset>,
    /// Default preset name
    pub default_preset: Option<String>,
}

impl ProjectConfig {
    /// Load configuration from a project directory
    pub fn load(project_path: &Path) -> Result<Self, ConfigError> {
        let config_path = project_path.join(CONFIG_DIR).join(CONFIG_FILE);

        if !config_path.exists() {
            return Ok(Self::default());
        }

        let content = std::fs::read_to_string(&config_path)?;
        let config: ProjectConfig = toml::from_str(&content)?;
        Ok(config)
    }

    /// Get a preset by name
    pub fn get_preset(&self, name: &str) -> Option<&AgentPreset> {
        self.presets.iter().find(|p| p.name == name)
    }

    /// Get the default preset
    pub fn default_preset(&self) -> Option<&AgentPreset> {
        self.default_preset
            .as_ref()
            .and_then(|name| self.get_preset(name))
    }
}
