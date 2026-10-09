# StrictlyHealth

Your ring. Your watch. Your data.

An independent, local-first iPhone dashboard for Oura ring records and read-only
Apple Health data. Built with SwiftUI, Swift Charts and Rust. No app backend,
Oura API subscription, proprietary model download or bundled health database.

## Features

- Battery and supported ring history over Bluetooth with your own key.
- Oura and Apple Watch measurements without double-counting activity or mixing HRV methods.
- Actual sleep stages, sleep/wake times, deep/REM/core durations, recorded awakenings and overnight physiology when available.
- Direct Bluetooth Oura sleep by default, with no silent Apple Health fallback. Today and Sleep name the actual source; Apple Watch sleep and automatic fallback are explicit Settings choices.
- Time in bed, sleep efficiency and time to fall asleep, plus longest recorded sleep stretch, sleep-window midpoint and seven-night bedtime consistency. Calculations use recorded intervals—not guessed sleep stages.
- Fahrenheit skin-temperature readouts and temperature differences; original Celsius records stay intact.
- Local Oura account export import for historical scores, contributors, sessions, stress/resilience and other dated fields.
- Live Sleep and Activity goal scores with editable targets and transparent breakdowns; custom Recovery uses comparable personal baselines. All are independent experimental formulas, not Oura algorithms or clinical assessments.
- Dated history and live trends. Historical imports remain separate from live scores and charts.
- A sleep-first native Today screen that opens separate Sleep, Activity and Recovery reports. Sleep includes timing, stage durations/shares, awakenings, a touch-to-inspect timeline, overnight HR/HRV and a seven-day comparison. Activity and Recovery have their own focused charts. HRV methods/device identities are not joined; display signals are bounded without removing originals.
- Color-banded app-score readouts, a native launch screen, and a top-right ring battery/connection indicator. Repeated technical subtitles are replaced by expandable source/score details; estimates remain identifiable. Foreground battery checks are bounded and do not drain history.

## Build

Use [the public build guide](docs/public/BUILD.md). Patched Bluetooth dependencies
ship here with their licenses. Configure your own bundle ID and Apple signing
team in a gitignored local file. Requires iOS 17+, Xcode and suitable provisioning.

Do not reset or re-pair an existing ring just to update this app.

Each morning, open **Ring → Sync ring** to download the recorded night. Opening
the app refreshes battery/status only; it does not automatically download history.
See [sleep insights and formulas](docs/public/SLEEP.md).

## Compatibility

Gen 3 Horizon authentication/sync has been confirmed on one physical ring in this
fork. Ring 4 uses the shared protocol but is untested here; Ring 5 has upstream
evidence but is also untested in this fork. Legacy/unknown rings can use import
and available Apple Health records without a live connection. This is not a claim
of universal ring support. See [the matrix](docs/public/COMPATIBILITY.md).

BLE cannot restore history erased by a reset. Official Oura scores remain imported
historical results. Live app scores are explicitly our own goal-based formulas,
not official equivalents. Direct-ring steps/energy currently use activity-intensity
estimates and are labeled accordingly. Missing data stays unavailable. Recorded
awakenings are not clinical EEG arousals.
This is experimental software, not a medical device.

## Privacy and release

Health records stay on the iPhone; keys use device-only Keychain storage. Device
backups, manual exports and diagnostics may still contain sensitive data. Read
[the release checklist](docs/public/RELEASING.md) and use the curated source
packager before uploading anything. Never post pairing keys, health exports,
database files, local signing configuration or identifiable diagnostics in issues.

Based on [Open Health](https://github.com/Th0rgal/open_health) and
[Open Oura](https://github.com/Th0rgal/open_oura). Cracked-Oura is a visual/workflow
reference, not copied frontend code or a bundled dependency.
[Third-party notices](THIRD_PARTY_NOTICES.md) · [MIT license](LICENSE).
