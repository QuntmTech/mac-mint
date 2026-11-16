//! MacMint for Windows: the engine. Everything that finds, judges, moves and restores files lives
//! here, independent of the window, so it can be tested on any machine with temporary folders.
pub mod apps;
pub mod cleanup;
pub mod developer;
pub mod executor;
pub mod fs;
pub mod history;
pub mod model;
pub mod paths;
pub mod plan;
pub mod process;
pub mod recommend;
pub mod safety;
pub mod startup;
pub mod storage;
pub mod system;
pub mod trash;
