# Youra insights

These are descriptive, experimental calculations, not diagnoses, validated risk
predictions, causal estimates, or proprietary Oura scores.

The latest valid selected-source night anchors the brief and comparison period.
The app labels its date; older cached nights must not be read as last night.
Eligible nights need positive duration, valid ordered timestamps, an actual sleep
onset/end, and at least 95% recorded stage coverage. Account exports are excluded.
Candidates must match sleep source, exact private device identity, and HRV method.
Only their friendly transport/source label appears in shareable summaries.

| Feature | Calculation and exclusions |
| --- | --- |
| Habit patterns | Median sleep hours, efficiency, recorded awakenings or latency for confirmed Yes versus confirmed No. Unknown and unlogged days excluded. |
| Workout timing | Last recorded workout end in the 24 elapsed hours before sleep onset; compare within two hours versus earlier. Nights without such a record are excluded, not called rest days. No intensity inference. |
| Schedule drift | Explicit Free day Yes versus No (work day). Compare onset, wake and elapsed-window midpoint as local clock minutes, unwrapped around the latest night across midnight. Not SRI or a circadian-phase estimate. |
| HR shape | Median actual samples in the first and last thirds of the recorded sleep window. Each needs at least three distinct timestamps spanning 65% of that third, with no gap above one-third of its duration (minimum gap allowance five minutes). |
| Lowest HR window | Lowest median of fully contained 15-minute windows beginning at actual sample times, requiring three distinct timestamps spanning 65% of the window and no gap above five minutes. The reported time is the window start, not a predicted biological settling time. |
| Morning baseline | Sleep-duration difference from the median of at least 14 preceding comparable nights in the previous 28 calendar days, excluding the current night. |

Comparisons use 60 calendar dates ending with the latest valid night and need five
eligible measurements on each side **per outcome**. That threshold is not a
statistical-significance test. Every comparison shows counts, supporting dates,
source and a chart. No confidence percentage or causal language is generated.
HR values outside 25–240 bpm, nonfinite values and duplicate timestamps are
excluded from these descriptive HR summaries, not erased from stored originals.

Check-ins are assigned to a reviewed **wake-up date**. Evening events normally
belong to the next morning. AM/PM and event dates are editable. Contradictory or
uncertain speech produces Unknown and clarification; partial transcripts do not
save anything. The parser is a conservative English rule system, not a general
language model. Review is mandatory, especially negation and multiple clauses.

Travel, sleep stage distribution, illness, selection bias and unlogged habits can
confound all findings. Daylight-saving duration uses real elapsed timestamps;
schedule comparisons use the current device time zone. Original per-event travel
time zones are not available: comparisons across travel require extra caution.

Synthetic tests cover midnight, DST, source/method separation, sparse/duplicate
samples, missing stages, cohort thresholds, and journal parsing. They do not
validate clinical accuracy or additional ring generations.
