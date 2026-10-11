#!/bin/bash
# Curated source only. This never publishes, deletes, or copies local signing/data.
set -euo pipefail
cd "$(dirname "$0")/.."
REPO="$PWD"
mkdir -p "$REPO/release"
BUNDLE=$(mktemp -d "$REPO/release/Youra.XXXXXX")
mkdir -p "$BUNDLE/apps/ios/OuraApp" "$BUNDLE/apps/ios/generated/headers" "$BUNDLE/crates" "$BUNDLE/vendor" "$BUNDLE/tools/morning-brief" "$BUNDLE/docs" "$BUNDLE/.github/workflows"
cp Cargo-public.toml "$BUNDLE/Cargo.toml"
cp LICENSE README.md THIRD_PARTY_NOTICES.md .gitignore "$BUNDLE/"
cp -R crates/oura-core crates/oura-summary "$BUNDLE/crates/"
cp -R vendor/open_oura vendor/oura-store "$BUNDLE/vendor/"
cp -R docs/public "$BUNDLE/docs/"
cp apps/ios/build-xcframework.sh "$BUNDLE/apps/ios/"
cp apps/ios/generated/headers/module.modulemap "$BUNDLE/apps/ios/generated/headers/"
cp tools/check-public.py tools/package-public.sh "$BUNDLE/tools/"
cp tools/morning-brief/install.py tools/morning-brief/server.py tools/morning-brief/test_server.py "$BUNDLE/tools/morning-brief/"
cp Cargo-public.toml "$BUNDLE/Cargo-public.toml"
cp .github/workflows/public-ios.yml "$BUNDLE/.github/workflows/"
APP="$REPO/apps/ios/OuraApp"
for file in OuraApp.swift Models.swift Core.swift WorkCoordinator.swift Components.swift Reports.swift DayExport.swift RawData.swift HeartRate.swift Theme.swift BLETransport.swift RingSync.swift ProfileSettings.swift ModelProgress.swift CrashCatch.c CrashCatch.h Diagnostics.swift HealthExport.swift Info-personal.plist PersonalHealth.entitlements project-personal.yml project-public.yml Public.xcconfig Signing.example.xcconfig LaunchScreen.storyboard; do
  cp "$APP/$file" "$BUNDLE/apps/ios/OuraApp/"
done
cp -R "$APP/Personal" "$APP/PersonalTests" "$APP/Assets.xcassets" "$BUNDLE/apps/ios/OuraApp/"
if [ -f PRODUCT.md ]; then cp PRODUCT.md "$BUNDLE/"; fi
if [ -f DESIGN.md ]; then cp DESIGN.md "$BUNDLE/"; fi
# Generated lockfile is scoped to the lean public workspace, never the research tools.
(cd "$BUNDLE" && cargo generate-lockfile --offline)
python3 tools/check-public.py "$BUNDLE"
echo "Prepared source bundle: $BUNDLE"
