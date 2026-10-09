# Sleep insights

These are descriptive calculations, not medical assessments or Oura algorithms.
Download the recorded night with Ring → Sync ring. Account exports are optional
historical backfill and never become live app scores or weekly live insights.

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
