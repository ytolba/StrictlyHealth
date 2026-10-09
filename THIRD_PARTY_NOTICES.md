# Third-party notices

This project builds on [Open Health](https://github.com/Th0rgal/open_health)
and [Open Oura](https://github.com/Th0rgal/open_oura), by Thomas Marchand.
Their MIT licenses and copyright notices are preserved. Reviewed protocol,
transport and analysis sources are vendored in `vendor/open_oura`; the patched
storage crate is in `vendor/oura-store`.

[Cracked-Oura](https://github.com/EIrno/Cracked-Oura) is a visual/workflow reference
and an account-export format reference, not a bundled dependency. No branding,
artwork, frontend source, backend source or distribution binary from that project
is shipped here. The account importer and native views are original implementations.

Rust dependency licenses are declared in their crates and locked in `Cargo.lock`.
Before distributing binaries, inventory those dependencies and retain required
notices; this file is not a substitute for a complete binary license audit.

Oura, Apple, Apple Watch and HealthKit are trademarks of their respective owners.
This independent project is not affiliated with or endorsed by those companies.
