# Build Youra

## Prerequisites

A Mac, Xcode with an iOS SDK, Rust/rustup, XcodeGen, and an iPhone running iOS 17+.
The public app requires no proprietary model files, seeded health database, Oura API
credentials, server account or backend. Optional Hermes uses your own server. All required patched Rust sources are in
this repository; a sibling `open_oura` checkout is no longer required.

```sh
git clone https://github.com/ytolba/StrictlyHealth.git
cd StrictlyHealth
brew install xcodegen
rustup target add aarch64-apple-ios aarch64-apple-ios-sim
bash apps/ios/build-xcframework.sh
cd apps/ios/OuraApp
cp Signing.example.xcconfig Signing.local.xcconfig
```

Edit `Signing.local.xcconfig` with your own Apple development team and a unique
bundle ID. This file is gitignored and must never be included in a public bundle.
Existing users upgrading this app must keep their current bundle ID and team to
retain their installation, data and device-only Keychain access.

```sh
xcodegen generate --spec project-public.yml
open OuraApp.xcodeproj
```

Select your connected iPhone and Run. Keep the HealthKit and Bluetooth capabilities
enabled. Provisioning must support HealthKit; a free Apple Personal Team may not
support the required capabilities. This project's lack of an Oura membership does
not remove Apple's code-signing requirements.

## First launch

1. Connect Apple Health and allow only the read permissions you want. Apple Watch
   is optional; denied/unavailable data stays unavailable.
2. Alternatively, import your unzipped Oura account export in Settings. This works
   without pairing or Apple Health permission.
3. For live ring sync, choose the model and read its compatibility note before
   entering your existing key. Close other Bluetooth clients and keep the ring nearby.
4. Choose preferred sources and dashboard metrics. HRV methods remain separate;
   unlike devices are not summed into one activity total.

## Recording and reading sleep

Wear your ring overnight, then open the app in the morning. The ring
records supported measurements; this app downloads them during history sync.
Opening the app starts history sync with a saved key and supported ring. Manual
**Ring → Sync ring** remains available. Sleep is filed under the wake-up date.
Tap Sleep on Today
for essentials, stages, awakenings, continuity, weekly rhythm and physiology.
Missing or incomplete stages stay unavailable. Firmware determines which metrics
the ring supplies; this project does not promise every official Oura metric.

In **Settings → Preferred source → Sleep source**, choose **Oura · direct Bluetooth**
for ring-only sleep. It never substitutes Apple Health sleep when ring data is missing
or incomplete. **Apple Watch · Apple Health** reads Watch sleep only; **Automatic
fallback** explicitly enables source fallback. Older installations retain an explicitly
selected Watch preference; otherwise they use direct Oura. Today and Sleep show the
actual source and transport. A successful sync alone does not prove a complete night.

Skin temperature is shown in °F. Raw storage remains Celsius. A temperature
deviation is converted as a difference (×1.8), not an absolute temperature.
Read [the formulas](SLEEP.md) for coverage requirements and interpretation.

## Battery and connection

Cold launch attempts a history sync with the existing device-only key, refreshing
battery as part of it. Rapid foreground changes are coalesced; normal returns use a
three-minute cooldown, while interrupted transfers resume from their checkpoint.
The loading screen lets you continue with saved data during transfer, or retry after
a failure. An automatic fresh scan waits up to 10 seconds for Bluetooth. If unreachable, the saved
percentage stays visible; tap the top-right indicator for its timestamp and retry.
“Connected” means the current authenticated link, not a successful sync sometime
in the past. The app releases this status link in the background and on full sync.
Other Bluetooth clients can prevent a connection; close them or use the charger.

Score colors use this app's presentation bands: High (85+), Moderate (70–84), Low
(below 70). They are not clinical thresholds or a replacement for Oura algorithms.

See [compatibility](COMPATIBILITY.md) before pairing, and
[release checks](RELEASING.md) before publishing.

## Voice and patterns

Tap **Today → Talk to Youra → Check-in**. Record a short English turn or type;
review the wake-up date, each Yes/No/Unknown answer, and optional event times,
then Save. Missing answers are never interpreted as No. You can edit a saved date.
Speech uses local recognition only; unsupported devices/languages and denied
permissions have a typed fallback. There is no automatic network transcription.

**Today → Your patterns** and **Trends → Your patterns** show comparisons and
their supporting nights. See [insight formulas](INSIGHTS.md). The morning brief
uses the latest valid night and explicitly dates it, including when it is older.
Use [the Hermes guide](HERMES.md) for optional spoken explanations. No AI setup
is needed for measurements, check-ins, patterns, or the morning brief.

## Tests

```sh
cargo test --locked -p oura-core --lib
cd apps/ios/OuraApp
xcodebuild test -project OuraApp.xcodeproj -scheme OuraApp \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' CODE_SIGNING_ALLOWED=NO
```

Select a simulator installed on your Mac if that model is absent. Simulator tests
cannot verify Bluetooth, actual ring firmware, HealthKit permissions or Apple Watch
delivery. Validate those separately with consent and report the specific capability.
