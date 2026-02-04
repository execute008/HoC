//! Git worktree operations
//!
//! Manages git worktrees for isolated agent workspaces.

use git2::{BranchType, Repository};
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
    #[error("Branch not found: {0}")]
    BranchNotFound(String),
    #[error("Invalid worktree path: {0}")]
    InvalidPath(String),
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

/// Create a new worktree for the specified branch
///
/// # Arguments
/// * `repo` - The repository to create the worktree in
/// * `worktree_path` - Path where the worktree will be created
/// * `branch_name` - Name of the branch to checkout in the worktree
///
/// # Returns
/// * `Ok(WorktreeInfo)` - Information about the created worktree
/// * `Err(GitError)` - If creation fails
pub fn create_worktree(
    repo: &Repository,
    worktree_path: &Path,
    branch_name: &str,
) -> Result<WorktreeInfo, GitError> {
    // Validate worktree path
    if worktree_path.as_os_str().is_empty() {
        return Err(GitError::InvalidPath("Worktree path cannot be empty".into()));
    }

    // Check if worktree already exists at this path
    if worktree_path.exists() {
        return Err(GitError::WorktreeExists(
            worktree_path.display().to_string(),
        ));
    }

    // Check if a worktree with this name already exists
    let worktree_name = worktree_path
        .file_name()
        .and_then(|n| n.to_str())
        .ok_or_else(|| GitError::InvalidPath("Invalid worktree name".into()))?;

    if repo.find_worktree(worktree_name).is_ok() {
        return Err(GitError::WorktreeExists(worktree_name.to_string()));
    }

    // Find or create the branch
    let branch = match repo.find_branch(branch_name, BranchType::Local) {
        Ok(branch) => branch,
        Err(_) => {
            // Try to find remote branch and create local tracking branch
            let remote_branch_name = format!("origin/{}", branch_name);
            match repo.find_branch(&remote_branch_name, BranchType::Remote) {
                Ok(remote_branch) => {
                    let commit = remote_branch.get().peel_to_commit()?;
                    repo.branch(branch_name, &commit, false)?
                }
                Err(_) => return Err(GitError::BranchNotFound(branch_name.to_string())),
            }
        }
    };

    // Get the reference for the branch
    let reference = branch.into_reference();

    // Create the worktree
    repo.worktree(worktree_name, worktree_path, Some(git2::WorktreeAddOptions::new().reference(Some(&reference))))?;

    Ok(WorktreeInfo {
        path: worktree_path.display().to_string(),
        branch: Some(branch_name.to_string()),
        is_main: false,
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::fs;
    use tempfile::TempDir;

    fn create_test_repo() -> (TempDir, Repository) {
        let temp_dir = TempDir::new().expect("Failed to create temp dir");
        let repo = Repository::init(temp_dir.path()).expect("Failed to init repo");

        // Create an initial commit so we have a valid HEAD
        {
            let signature = repo.signature().unwrap_or_else(|_| {
                git2::Signature::now("Test", "test@example.com").unwrap()
            });
            let tree_id = repo.index().unwrap().write_tree().unwrap();
            let tree = repo.find_tree(tree_id).unwrap();
            repo.commit(
                Some("HEAD"),
                &signature,
                &signature,
                "Initial commit",
                &tree,
                &[],
            )
            .expect("Failed to create initial commit");
        }

        (temp_dir, repo)
    }

    #[test]
    fn test_is_git_repository_true() {
        let (temp_dir, _repo) = create_test_repo();
        assert!(is_git_repository(temp_dir.path()));
    }

    #[test]
    fn test_is_git_repository_false() {
        let temp_dir = TempDir::new().expect("Failed to create temp dir");
        assert!(!is_git_repository(temp_dir.path()));
    }

    #[test]
    fn test_open_repository_success() {
        let (temp_dir, _repo) = create_test_repo();
        let result = open_repository(temp_dir.path());
        assert!(result.is_ok());
    }

    #[test]
    fn test_open_repository_not_a_repo() {
        let temp_dir = TempDir::new().expect("Failed to create temp dir");
        let result = open_repository(temp_dir.path());
        assert!(matches!(result, Err(GitError::NotARepository(_))));
    }

    #[test]
    fn test_list_worktrees_main_only() {
        let (temp_dir, repo) = create_test_repo();
        let worktrees = list_worktrees(&repo).expect("Failed to list worktrees");

        assert_eq!(worktrees.len(), 1);
        assert!(worktrees[0].is_main);
        assert!(worktrees[0].path.contains(temp_dir.path().to_str().unwrap()));
    }

    #[test]
    fn test_create_worktree_success() {
        let (temp_dir, repo) = create_test_repo();

        // Create a new branch first
        let head_commit = repo.head().unwrap().peel_to_commit().unwrap();
        repo.branch("feature-branch", &head_commit, false)
            .expect("Failed to create branch");

        // Create worktree
        let worktree_path = temp_dir.path().join("worktrees").join("feature-branch");
        fs::create_dir_all(temp_dir.path().join("worktrees")).unwrap();

        let result = create_worktree(&repo, &worktree_path, "feature-branch");
        assert!(result.is_ok());

        let info = result.unwrap();
        assert_eq!(info.branch, Some("feature-branch".to_string()));
        assert!(!info.is_main);
        assert!(worktree_path.exists());
    }

    #[test]
    fn test_create_worktree_branch_not_found() {
        let (temp_dir, repo) = create_test_repo();

        let worktree_path = temp_dir.path().join("worktrees").join("nonexistent");
        fs::create_dir_all(temp_dir.path().join("worktrees")).unwrap();

        let result = create_worktree(&repo, &worktree_path, "nonexistent-branch");
        assert!(matches!(result, Err(GitError::BranchNotFound(_))));
    }

    #[test]
    fn test_create_worktree_path_exists() {
        let (temp_dir, repo) = create_test_repo();

        // Create the target path first
        let worktree_path = temp_dir.path().join("existing-dir");
        fs::create_dir_all(&worktree_path).unwrap();

        let result = create_worktree(&repo, &worktree_path, "main");
        assert!(matches!(result, Err(GitError::WorktreeExists(_))));
    }

    #[test]
    fn test_create_worktree_empty_path() {
        let (_temp_dir, repo) = create_test_repo();

        let result = create_worktree(&repo, Path::new(""), "main");
        assert!(matches!(result, Err(GitError::InvalidPath(_))));
    }

    #[test]
    fn test_list_worktrees_after_create() {
        let (temp_dir, repo) = create_test_repo();

        // Create a new branch
        let head_commit = repo.head().unwrap().peel_to_commit().unwrap();
        repo.branch("test-branch", &head_commit, false)
            .expect("Failed to create branch");

        // Create worktree
        let worktree_path = temp_dir.path().join("worktrees").join("test-branch");
        fs::create_dir_all(temp_dir.path().join("worktrees")).unwrap();
        create_worktree(&repo, &worktree_path, "test-branch").expect("Failed to create worktree");

        // List worktrees
        let worktrees = list_worktrees(&repo).expect("Failed to list worktrees");
        assert_eq!(worktrees.len(), 2);

        let main_wt = worktrees.iter().find(|w| w.is_main).unwrap();
        let linked_wt = worktrees.iter().find(|w| !w.is_main).unwrap();

        assert!(main_wt.is_main);
        assert!(!linked_wt.is_main);
        assert_eq!(linked_wt.branch, Some("test-branch".to_string()));
    }
}
