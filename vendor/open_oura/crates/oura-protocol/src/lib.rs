//! `oura-protocol` — the Oura ring BLE wire language and decoders, pure and I/O-free.
//!
//! This is the *interpretation (low level)* layer: it defines the packet framing,
//! request builders, app-auth crypto, and the decoders that turn raw event bodies
//! into typed physiological samples. It has no Bluetooth, async, or storage deps,
//! so it is fully unit-testable.
pub mod auth;
pub mod device;
pub mod events;
pub mod protocol;
