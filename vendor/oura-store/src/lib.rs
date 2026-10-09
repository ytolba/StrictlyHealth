//! `oura-store` — the *apply* layer: persisting and querying ring data in SQLite
//! (raw events kept lossless, plus a sync cursor and scalar readings).
pub mod error;
pub mod storage;

pub use error::{Error, Result};
pub use storage::Store;
