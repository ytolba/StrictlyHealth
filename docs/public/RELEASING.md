# Before a public GitHub release

- Use `tools/package-public.sh` to produce a curated source bundle. Never upload
  the entire working directory or `target`, `local`, `dna`, captures, exports,
  generated projects, frameworks, signing files, certificates or health databases.
- Run `tools/check-public.py <bundle-directory>` and inspect the result yourself.
  A scan is a guardrail, not proof that no sensitive information exists.
- Keep MIT notices, THIRD_PARTY_NOTICES.md and dependency license requirements.
- Use synthetic screenshots that are explicitly labeled Demo. No real user's
  health readings or device identifiers should appear in public images.
  A Debug build accepts `--demo-dashboard` as a launch argument for an isolated
  synthetic preview. It does not query HealthKit, connect Bluetooth, import files
  or persist demo records. Release builds ignore this argument.
- Publish capability-by-capability support notes. Ring 4/5 testing is still owed;
  do not turn protocol-level support into an all-rings claim.
- Run Rust and simulator tests from the clean bundle, then validate physical
  pairing, reconnection, battery, overnight sleep, import and read-only HealthKit.
- Do not market this as a medical device, Oura's official app, or a reproduction
  of every proprietary score. Custom recovery and imported official scores differ.
- Do not put pairing keys or personal exports in GitHub issues. Diagnostics can
  still be sensitive even after automated identifier redaction.
- Decide a repository URL and binary distribution/signing strategy separately.
  Preparing this bundle does not publish anything or grant public access.

The public source build is iPhone-first. Upstream desktop/research tools remain in
the development checkout, but are not the shipping public app and are not included
in the curated iPhone release bundle.
