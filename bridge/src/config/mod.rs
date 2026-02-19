//! Configuration module
//!
//! Handles loading and saving project configuration and workspace layouts.

#[allow(dead_code)]
mod project;
#[allow(dead_code)]
mod workspace;

pub use project::*;
#[allow(unused_imports)]
pub use workspace::*;
