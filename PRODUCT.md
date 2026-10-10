# StrictlyHealth

<!-- impeccable:product-schema 1 -->

## Platform
ios

## Users
Oura ring and Apple Watch owners who want an independent everyday health dashboard. Public source should support other users without containing personal signing, health records or pairing keys.

## Product Purpose
Replace the daily dashboard workflow with local ring Bluetooth data and read-only Apple Health. Account exports are optional historical backfill, not a dependency for live scores or charts.

## Operating Context
An iPhone app with ring battery/connection status, foreground automatic history sync with a recoverable loading screen, manual history sync, daily sleep and activity detail, trends, history and source preferences.
Today is sleep-first, opening separate Sleep, Activity and Recovery pages. Technical explanations remain available through disclosures rather than repeated subtitles.

## Capabilities and Constraints
Use direct Bluetooth Oura sleep by default, without silent Apple Health substitution. Watch-only sleep and automatic sleep fallback are explicit options; other measurements retain preferred-source fallback. Calculate transparent app-owned Sleep and Activity scores; keep them distinct from proprietary Oura scores and medical assessments. Never manufacture missing sleep stages, oxygen, HRV or activity. Direct ring steps are currently estimates and must be labeled. Preserve pairing and stored history. Ring generation support depends on verified protocol capabilities, not a blanket compatibility claim.

## Brand Commitments
User requested an Oura-influenced native experience with an independent twist, rich data charts, colored scores and Apple Health integration. Preserve familiar iPhone navigation and accessibility.
App-facing identity is StrictlyHealth with an original SH monogram; preserve the existing bundle identifier and local data during branding updates.

## Evidence on Hand
Existing SwiftUI app and synthetic dashboard fixtures. One Gen 3 ring sync has been verified; other generations and complete overnight data coverage remain limited evidence. Synthetic screenshots are labeled. No clinical validation of custom scores exists.

## Product Principles
- Live measurements first; archive imports belong to history.
- One selected source per measurement, with explicit fallback and provenance.
- Explain formulas and distinguish estimates from measurements.
- Keep health records and keys local.
- Smooth interaction, native accessibility and honest missing-data states.
