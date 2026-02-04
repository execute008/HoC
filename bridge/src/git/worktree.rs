//! Git worktree operations
//!
//! Manages git worktrees for isolated agent workspaces.

use git2::Repository;
use std::path::Path;
use thiserror::Error;

/// Errors that can occur during git operations
#[derive(Error, Debug)]
pub enum GitError {
    #[error("Not a git repository: {0}")]
    NotARepository(String),
    #[error("Git operation failed: {0}")]
    Git(#[from] git2::Error),
    #[error("Worktree already exists: {0}")]
    WorktreeExists(String),
}

/// Information about a git worktree
#[derive(Debug, Clone)]
pub struct WorktreeInfo {
    /// Path to the worktree
    pub path: String,
    /// Branch name
    pub branch: Option<String>,
    /// Whether this is the main worktree
    pub is_main: bool,
}

/// Check if a path is inside a git repository
pub fn is_git_repository(path: &Path) -> bool {
    Repository::discover(path).is_ok()
}

/// Get repository for a path
pub fn open_repository(path: &Path) -> Result<Repository, GitError> {
    Repository::discover(path).map_err(|_| GitError::NotARepository(path.display().to_string()))
}

/// List all worktrees for a repository
pub fn list_worktrees(repo: &Repository) -> Result<Vec<WorktreeInfo>, GitError> {
    let worktrees = repo.worktrees()?;
    let mut result = Vec::new();

    // Add main worktree
    if let Some(workdir) = repo.workdir() {
        let head = repo.head().ok();
        let branch = head
            .as_ref()
            .and_then(|h| h.shorthand())
            .map(String::from);

        result.push(WorktreeInfo {
            path: workdir.display().to_string(),
            branch,
            is_main: true,
        });
    }

    // Add linked worktrees
    for name in worktrees.iter().flatten() {
        if let Ok(wt) = repo.find_worktree(name) {
            if let Some(path) = wt.path().to_str() {
                result.push(WorktreeInfo {
                    path: path.to_string(),
                    branch: Some(name.to_string()),
                    is_main: false,
                });
            }
        }
    }

    Ok(result)
}
