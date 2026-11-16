//! MacMint for Windows: the engine. Everything that finds, judges, moves and restores files lives
//! here, independent of the window, so it can be tested on any machine with temporary folders.
pub mod developer;
pub mod executor;
pub mod fs;
pub mod history;
pub mod model;
pub mod paths;
pub mod plan;
pub mod process;
pub mod safety;
pub mod trash;
