# Sleep insights

These are descriptive calculations, not medical assessments or Oura algorithms.
Opening the app downloads history with the saved pairing key; Ring → Sync ring
is also available manually. Sleep is filed under its wake-up date. Account exports are optional
historical backfill and never become live app scores or weekly live insights.

The default sleep mode is **Oura · direct Bluetooth**: missing or incomplete direct
ring records stay unavailable, even if Apple Health has a complete night. Watch-only
sleep and automatic fallback are explicit options in Settings. The source shown on
Today and Sleep distinguishes direct Bluetooth, Apple Watch via Apple Health, Oura
app records via Apple Health, and historical account exports. Stage timelines are
never combined across those sources. Sync completion is not proof of complete stages.

Direct ring epochs retain their reported 30-second duration and stage labels;
they are not smoothed or reclassified as deep sleep. Delayed analysis packets are
aligned to an explicit bed window only when separate sleep-summary offsets agree,
the boot clock matches, and a complete page burst fits with less than one page of
trailing padding. Conflicting or incomplete records are not stretched to fit.

| Readout | Calculation and limits |
| --- | --- |
| Time in bed | Recorded bed end minus recorded bed start. Without a known bed window, unavailable. |
| Efficiency | Recorded sleep duration divided by time in bed, ×100. Impossible durations are rejected. |
| Time to fall asleep | First recognized asleep interval minus known bed start. For direct-ring data, the preceding interval must be covered by awake epochs; missing epochs are not assumed awake. This is a recorded-window estimate, not a measurement of when you tried to sleep. |
| Longest recorded sleep stretch | Merge adjacent/overlapping recognized asleep intervals. Awake periods and gaps break the stretch. Partial nights can show a recorded stretch, not necessarily the longest of the whole night. |
| Sleep-window midpoint | Halfway between first and last recognized sleep, including intervening awakenings. Requires at least 95% timeline coverage. Not a circadian-phase measurement. |
| Typical bedtime variation | Median absolute distance from the week's median sleep-onset clock time. The seven wake-date days ending on the selected day need at least three covered nights from the same source/device. Overnight times wrap across midnight. This convention is intended for overnight sleep, not rotating shift-work comparisons. |
| Typical sleep | Median recorded sleep duration across the same qualifying nights. |
| Sleep goal met | Nights meeting your editable sleep-duration goal out of qualifying recorded nights. Missing nights are excluded, not counted as failures. |

Awakenings are merged recorded awake spans between first and last sleep—not EEG
arousals. Unspecified asleep records are not guessed into deep, light or REM.
Daily physiology is not necessarily measured within the selected sleep session.

Absolute skin temperature: °F = °C ×1.8 +32. Temperature deviation: Δ°F = Δ°C ×1.8.
This affects presentation and chart axes only; stored measurements and raw imported
fields remain in their original units. Skin/wrist temperature is not core body temperature.
