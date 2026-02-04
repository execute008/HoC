//! Workspace layout configuration
//!
//! Loads and saves workspace layouts to .hoc/workspace.json

use serde::{Deserialize, Serialize};
use std::path::Path;
use thiserror::Error;

use super::{CONFIG_DIR, WORKSPACE_FILE};

/// Errors that can occur during workspace operations
#[derive(Error, Debug)]
pub enum WorkspaceError {
    #[error("Failed to read workspace file: {0}")]
    Read(#[from] std::io::Error),
    #[error("Failed to parse workspace: {0}")]
    Parse(#[from] serde_json::Error),
}

/// Position of an element in the workspace
#[derive(Debug, Clone, Serialize, Deserialize, Default, PartialEq)]
pub struct Position {
    /// X coordinate
    pub x: f32,
    /// Y coordinate
    pub y: f32,
    /// Z coordinate (depth/layer)
    #[serde(default)]
    pub z: f32,
}

/// Size of an element in the workspace
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct Size {
    /// Width
    pub width: f32,
    /// Height
    pub height: f32,
}

impl Default for Size {
    fn default() -> Self {
        Self {
            width: 1.0,
            height: 1.0,
        }
    }
}

/// Layout information for a single terminal/agent panel
#[derive(Debug, Clone, Serialize, Deserialize, Default, PartialEq)]
pub struct PanelLayout {
    /// Panel identifier (matches agent preset or custom name)
    pub id: String,
    /// Position in workspace
    #[serde(default)]
    pub position: Position,
    /// Size of the panel
    #[serde(default)]
    pub size: Size,
    /// Whether the panel is visible
    #[serde(default = "default_visible")]
    pub visible: bool,
    /// Terminal columns
    #[serde(default = "default_cols")]
    pub cols: u16,
    /// Terminal rows
    #[serde(default = "default_rows")]
    pub rows: u16,
}

fn default_visible() -> bool {
    true
}

fn default_cols() -> u16 {
    80
}

fn default_rows() -> u16 {
    24
}

/// A named workspace layout configuration
#[derive(Debug, Clone, Serialize, Deserialize, Default, PartialEq)]
pub struct WorkspaceLayout {
    /// Name of this layout
    pub name: String,
    /// Description of the layout
    #[serde(default)]
    pub description: Option<String>,
    /// Panel layouts within this workspace
    #[serde(default)]
    pub panels: Vec<PanelLayout>,
}

/// Root workspace configuration containing multiple layouts
#[derive(Debug, Clone, Serialize, Deserialize, Default, PartialEq)]
pub struct WorkspaceConfig {
    /// Available workspace layouts
    #[serde(default)]
    pub layouts: Vec<WorkspaceLayout>,
    /// Name of the active/default layout
    #[serde(default)]
    pub active_layout: Option<String>,
}

impl WorkspaceConfig {
    /// Load workspace configuration from a project directory
    pub fn load(project_path: &Path) -> Result<Self, WorkspaceError> {
        let workspace_path = project_path.join(CONFIG_DIR).join(WORKSPACE_FILE);

        if !workspace_path.exists() {
            return Ok(Self::default());
        }

        let content = std::fs::read_to_string(&workspace_path)?;
        let config: WorkspaceConfig = serde_json::from_str(&content)?;
        Ok(config)
    }

    /// Save workspace configuration to a project directory
    pub fn save(&self, project_path: &Path) -> Result<(), WorkspaceError> {
        let config_dir = project_path.join(CONFIG_DIR);

        // Create .hoc directory if it doesn't exist
        if !config_dir.exists() {
            std::fs::create_dir_all(&config_dir)?;
        }

        let workspace_path = config_dir.join(WORKSPACE_FILE);
        let content = serde_json::to_string_pretty(self)?;
        std::fs::write(&workspace_path, content)?;
        Ok(())
    }

    /// Get a layout by name
    pub fn get_layout(&self, name: &str) -> Option<&WorkspaceLayout> {
        self.layouts.iter().find(|l| l.name == name)
    }

    /// Get the active layout
    pub fn active_layout(&self) -> Option<&WorkspaceLayout> {
        self.active_layout
            .as_ref()
            .and_then(|name| self.get_layout(name))
    }

    /// Add or update a layout
    pub fn set_layout(&mut self, layout: WorkspaceLayout) {
        if let Some(existing) = self.layouts.iter_mut().find(|l| l.name == layout.name) {
            *existing = layout;
        } else {
            self.layouts.push(layout);
        }
    }

    /// Remove a layout by name
    pub fn remove_layout(&mut self, name: &str) -> Option<WorkspaceLayout> {
        if let Some(pos) = self.layouts.iter().position(|l| l.name == name) {
            // Clear active_layout if we're removing it
            if self.active_layout.as_deref() == Some(name) {
                self.active_layout = None;
            }
            Some(self.layouts.remove(pos))
        } else {
            None
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::fs;
    use tempfile::tempdir;

    #[test]
    fn test_default_workspace_config() {
        let config = WorkspaceConfig::default();
        assert!(config.layouts.is_empty());
        assert!(config.active_layout.is_none());
    }

    #[test]
    fn test_load_nonexistent_returns_default() {
        let dir = tempdir().unwrap();
        let config = WorkspaceConfig::load(dir.path()).unwrap();
        assert!(config.layouts.is_empty());
    }

    #[test]
    fn test_save_and_load_workspace() {
        let dir = tempdir().unwrap();

        let mut config = WorkspaceConfig::default();
        config.layouts.push(WorkspaceLayout {
            name: "default".to_string(),
            description: Some("Default layout".to_string()),
            panels: vec![PanelLayout {
                id: "main".to_string(),
                position: Position {
                    x: 0.0,
                    y: 0.0,
                    z: 0.0,
                },
                size: Size {
                    width: 2.0,
                    height: 1.5,
                },
                visible: true,
                cols: 120,
                rows: 40,
            }],
        });
        config.active_layout = Some("default".to_string());

        // Save
        config.save(dir.path()).unwrap();

        // Verify file exists
        let workspace_path = dir.path().join(CONFIG_DIR).join(WORKSPACE_FILE);
        assert!(workspace_path.exists());

        // Load and verify
        let loaded = WorkspaceConfig::load(dir.path()).unwrap();
        assert_eq!(loaded.layouts.len(), 1);
        assert_eq!(loaded.layouts[0].name, "default");
        assert_eq!(loaded.layouts[0].panels.len(), 1);
        assert_eq!(loaded.layouts[0].panels[0].cols, 120);
        assert_eq!(loaded.active_layout, Some("default".to_string()));
    }

    #[test]
    fn test_get_layout() {
        let mut config = WorkspaceConfig::default();
        config.layouts.push(WorkspaceLayout {
            name: "coding".to_string(),
            ..Default::default()
        });
        config.layouts.push(WorkspaceLayout {
            name: "review".to_string(),
            ..Default::default()
        });

        assert!(config.get_layout("coding").is_some());
        assert!(config.get_layout("review").is_some());
        assert!(config.get_layout("nonexistent").is_none());
    }

    #[test]
    fn test_active_layout() {
        let mut config = WorkspaceConfig::default();
        config.layouts.push(WorkspaceLayout {
            name: "main".to_string(),
            ..Default::default()
        });

        assert!(config.active_layout().is_none());

        config.active_layout = Some("main".to_string());
        assert!(config.active_layout().is_some());
        assert_eq!(config.active_layout().unwrap().name, "main");

        config.active_layout = Some("nonexistent".to_string());
        assert!(config.active_layout().is_none());
    }

    #[test]
    fn test_set_layout_add_new() {
        let mut config = WorkspaceConfig::default();

        config.set_layout(WorkspaceLayout {
            name: "new".to_string(),
            description: Some("New layout".to_string()),
            panels: vec![],
        });

        assert_eq!(config.layouts.len(), 1);
        assert_eq!(config.layouts[0].name, "new");
    }

    #[test]
    fn test_set_layout_update_existing() {
        let mut config = WorkspaceConfig::default();
        config.layouts.push(WorkspaceLayout {
            name: "existing".to_string(),
            description: Some("Old description".to_string()),
            panels: vec![],
        });

        config.set_layout(WorkspaceLayout {
            name: "existing".to_string(),
            description: Some("New description".to_string()),
            panels: vec![],
        });

        assert_eq!(config.layouts.len(), 1);
        assert_eq!(
            config.layouts[0].description,
            Some("New description".to_string())
        );
    }

    #[test]
    fn test_remove_layout() {
        let mut config = WorkspaceConfig::default();
        config.layouts.push(WorkspaceLayout {
            name: "to_remove".to_string(),
            ..Default::default()
        });
        config.active_layout = Some("to_remove".to_string());

        let removed = config.remove_layout("to_remove");
        assert!(removed.is_some());
        assert_eq!(removed.unwrap().name, "to_remove");
        assert!(config.layouts.is_empty());
        assert!(config.active_layout.is_none());
    }

    #[test]
    fn test_remove_nonexistent_layout() {
        let mut config = WorkspaceConfig::default();
        let removed = config.remove_layout("nonexistent");
        assert!(removed.is_none());
    }

    #[test]
    fn test_panel_layout_defaults() {
        let json = r#"{"id": "test"}"#;
        let panel: PanelLayout = serde_json::from_str(json).unwrap();

        assert_eq!(panel.id, "test");
        assert_eq!(panel.position.x, 0.0);
        assert_eq!(panel.position.y, 0.0);
        assert_eq!(panel.position.z, 0.0);
        assert_eq!(panel.size.width, 1.0);
        assert_eq!(panel.size.height, 1.0);
        assert!(panel.visible);
        assert_eq!(panel.cols, 80);
        assert_eq!(panel.rows, 24);
    }

    #[test]
    fn test_workspace_json_roundtrip() {
        let config = WorkspaceConfig {
            layouts: vec![WorkspaceLayout {
                name: "test".to_string(),
                description: None,
                panels: vec![
                    PanelLayout {
                        id: "agent1".to_string(),
                        position: Position {
                            x: -1.0,
                            y: 1.5,
                            z: 0.0,
                        },
                        size: Size {
                            width: 1.5,
                            height: 1.0,
                        },
                        visible: true,
                        cols: 100,
                        rows: 30,
                    },
                    PanelLayout {
                        id: "agent2".to_string(),
                        position: Position {
                            x: 1.0,
                            y: 1.5,
                            z: 0.0,
                        },
                        size: Size {
                            width: 1.5,
                            height: 1.0,
                        },
                        visible: false,
                        cols: 80,
                        rows: 24,
                    },
                ],
            }],
            active_layout: Some("test".to_string()),
        };

        let json = serde_json::to_string_pretty(&config).unwrap();
        let parsed: WorkspaceConfig = serde_json::from_str(&json).unwrap();

        assert_eq!(config, parsed);
    }

    #[test]
    fn test_creates_hoc_directory() {
        let dir = tempdir().unwrap();
        let config = WorkspaceConfig::default();

        // .hoc directory should not exist yet
        let hoc_dir = dir.path().join(CONFIG_DIR);
        assert!(!hoc_dir.exists());

        // Save should create it
        config.save(dir.path()).unwrap();
        assert!(hoc_dir.exists());
    }

    #[test]
    fn test_parse_invalid_json() {
        let dir = tempdir().unwrap();
        let hoc_dir = dir.path().join(CONFIG_DIR);
        fs::create_dir_all(&hoc_dir).unwrap();

        let workspace_path = hoc_dir.join(WORKSPACE_FILE);
        fs::write(&workspace_path, "invalid json {{{").unwrap();

        let result = WorkspaceConfig::load(dir.path());
        assert!(result.is_err());
    }
}
