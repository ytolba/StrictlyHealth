//! Symptom signs — the "something is brewing" readout, without a model.
//!
//! The app already has one of these: `IllnessModel.swift` runs Oura's own
//! `illness_detection` `.ptl` and emits NO / MINOR / MAJOR signs. It needs the model
//! file, which means the torch build, which means most builds show nothing. This is the
//! model-free version, over the same four biomarkers that model consumes:
//!
//! | biomarker | direction that suggests something |
//! |---|---|
//! | skin temperature deviation | up (and a sharp drop is also abnormal) |
//! | lowest resting HR | up |
//! | HRV | down |
//! | respiratory rate | up |
//!
//! Those four are not arbitrary — an elevated night-time respiratory rate and resting
//! HR alongside suppressed HRV is the pattern the COVID-era wearable studies keyed on
//! (Mishra et al., *Nat Biomed Eng* 2020; Radin et al., *Lancet Digit Health* 2020;
//! Natarajan et al., *NPJ Digit Med* 2020), and it is the same quartet Oura's own
//! Symptom Radar reports.
//!
//! ## Against your own baseline, robustly
//!
//! A population range is useless here: what matters is a change from *your* normal. The
//! baseline is the median and MAD of your recent nights, excluding the night being
//! judged, so a fever cannot quietly raise the bar it is measured against. MAD rather
//! than standard deviation because a couple of bad nights in a short history would
//! inflate an SD enough to hide the very deviation we are looking for.
//!
//! This is a wellness signal over four noisy numbers, not a diagnosis; short baselines
//! make it noisier still, which is why it stays silent below [`MIN_BASELINE_NIGHTS`].

use serde_json::{json, Value};

/// Nights of history required before any judgement is offered.
pub const MIN_BASELINE_NIGHTS: usize = 7;

/// Robust z beyond which a biomarker counts as deviating. ~2 robust SD: rare enough on
/// a normal night not to cry wolf every week.
const DEVIATION_Z: f64 = 2.0;
/// Robust z at which a single biomarker is severe enough to carry a MAJOR on its own
/// once anything else is also off.
const STRONG_Z: f64 = 3.0;

/// One night's four biomarkers. `None` where the night lacked that stream.
#[derive(Default, Clone, Copy)]
pub struct NightBiomarkers {
    pub skin_temp: Option<f64>,
    pub lowest_hr: Option<f64>,
    pub hrv_ms: Option<f64>,
    pub breath_rate: Option<f64>,
}

struct Marker {
    key: &'static str,
    label: &'static str,
    /// true when a HIGH value is the worrying direction
    high_is_bad: bool,
    /// Report the value as a change from baseline rather than as an absolute. Skin
    /// temperature only means something as a deviation — 34.9 °C is a number, "+0.6 °C
    /// above your normal" is a signal — and it is what the card labels it.
    as_deviation: bool,
    value: Option<f64>,
    history: Vec<f64>,
}

fn median(values: &mut Vec<f64>) -> Option<f64> {
    if values.is_empty() {
        return None;
    }
    values.sort_by(f64::total_cmp);
    let mid = values.len() / 2;
    Some(if values.len() % 2 == 0 {
        (values[mid - 1] + values[mid]) / 2.0
    } else {
        values[mid]
    })
}

/// Median absolute deviation, scaled to be comparable with a standard deviation on
/// normally-distributed data (the 1.4826 factor).
fn robust_sd(values: &[f64], center: f64) -> Option<f64> {
    let mut deviations: Vec<f64> = values.iter().map(|v| (v - center).abs()).collect();
    let mad = median(&mut deviations)?;
    (mad > 0.0).then_some(mad * 1.4826)
}

/// Judge `tonight` against `history` (previous nights, any order, newest-first or not).
///
/// Returns the same JSON shape the torch `IllnessResult` uses, so the existing card
/// renders either source unchanged: `{available, status, trafficLight, score, decision,
/// daysWithData, biomarkers[]}`.
pub fn symptom_signs(tonight: NightBiomarkers, history: &[NightBiomarkers], date: &str) -> Value {
    let markers = [
        Marker {
            key: "TemperatureDeviation",
            label: "skin temperature",
            high_is_bad: true,
            as_deviation: true,
            value: tonight.skin_temp,
            history: history.iter().filter_map(|n| n.skin_temp).collect(),
        },
        Marker {
            key: "LowestHeartRate",
            label: "resting heart rate",
            high_is_bad: true,
            as_deviation: false,
            value: tonight.lowest_hr,
            history: history.iter().filter_map(|n| n.lowest_hr).collect(),
        },
        Marker {
            key: "AverageHrv",
            label: "HRV",
            high_is_bad: false,
            as_deviation: false,
            value: tonight.hrv_ms,
            history: history.iter().filter_map(|n| n.hrv_ms).collect(),
        },
        Marker {
            key: "AverageBreath",
            label: "respiratory rate",
            high_is_bad: true,
            as_deviation: false,
            value: tonight.breath_rate,
            history: history.iter().filter_map(|n| n.breath_rate).collect(),
        },
    ];

    let usable = markers
        .iter()
        .filter(|m| m.value.is_some() && m.history.len() >= MIN_BASELINE_NIGHTS)
        .count();
    if usable == 0 {
        return json!({
            "available": false,
            "status": if history.len() < MIN_BASELINE_NIGHTS { "MISSING_SLEEP_DATA" } else { "MISSING_LAST_NIGHT_SLEEP" },
            "trafficLight": "",
            "score": 0.0,
            "decision": 0,
            "date": date,
            "daysWithData": history.len(),
            "biomarkers": [],
            "basis": "deviation from your own baseline",
        });
    }

    let mut biomarkers = Vec::new();
    let mut flags = 0;
    let mut strong = 0;
    let mut worst_z: f64 = 0.0;

    for marker in &markers {
        let (Some(value), true) = (marker.value, marker.history.len() >= MIN_BASELINE_NIGHTS)
        else {
            continue;
        };
        let mut history = marker.history.clone();
        let Some(center) = median(&mut history) else {
            continue;
        };
        let Some(sd) = robust_sd(&marker.history, center) else {
            continue;
        };
        let z = (value - center) / sd;
        // signed so that positive always means "the worrying direction"
        let bad_z = if marker.high_is_bad { z } else { -z };
        let deviating = bad_z >= DEVIATION_Z;
        if deviating {
            flags += 1;
            if bad_z >= STRONG_Z {
                strong += 1;
            }
        }
        worst_z = worst_z.max(bad_z);
        let origin = if marker.as_deviation { center } else { 0.0 };
        biomarkers.push(json!({
            "type": marker.key,
            "label": marker.label,
            "value": ((value - origin) * 100.0).round() / 100.0,
            // the band a normal night for you falls in
            "lower": ((center - origin - DEVIATION_Z * sd) * 100.0).round() / 100.0,
            "upper": ((center - origin + DEVIATION_Z * sd) * 100.0).round() / 100.0,
            "indicatesSymptoms": deviating,
            "reason": if !deviating {
                Value::Null
            } else if z > 0.0 {
                json!("ELEVATED")
            } else {
                json!("DECREASED")
            },
            "z": (bad_z * 10.0).round() / 10.0,
        }));
    }

    // Two biomarkers moving together is the pattern worth flagging; one alone is
    // usually a late meal, a hard session, or a warm room.
    let decision = if flags >= 3 || (flags >= 2 && strong >= 1) {
        2
    } else if flags >= 1 {
        1
    } else {
        0
    };
    let status = ["NO_SIGNS", "MINOR_SIGNS", "MAJOR_SIGNS"][decision as usize];

    json!({
        "available": true,
        "status": status,
        "trafficLight": status,
        // 0..1, how far the worst biomarker has travelled toward the strong threshold
        "score": ((worst_z.max(0.0) / STRONG_Z).min(1.0) * 100.0).round() / 100.0,
        "decision": decision,
        "date": date,
        "daysWithData": history.len(),
        "biomarkers": biomarkers,
        "basis": "deviation from your own baseline",
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    fn steady(n: usize) -> Vec<NightBiomarkers> {
        (0..n)
            .map(|i| {
                // a little natural wobble, alternating so the median stays put
                let wobble = if i % 2 == 0 { 0.1 } else { -0.1 };
                NightBiomarkers {
                    skin_temp: Some(35.0 + wobble),
                    lowest_hr: Some(50.0 + wobble * 10.0),
                    hrv_ms: Some(60.0 + wobble * 10.0),
                    breath_rate: Some(15.0 + wobble),
                }
            })
            .collect()
    }

    #[test]
    fn says_nothing_without_enough_history() {
        let history = steady(3);
        let v = symptom_signs(history[0], &history, "2026-09-14");
        assert_eq!(v["available"], false);
        assert_eq!(v["status"], "MISSING_SLEEP_DATA");
    }

    #[test]
    fn a_normal_night_is_quiet() {
        let history = steady(14);
        let v = symptom_signs(history[0], &history, "2026-09-14");
        assert_eq!(v["status"], "NO_SIGNS", "{v}");
        assert_eq!(v["decision"], 0);
    }

    #[test]
    fn one_biomarker_off_is_only_a_minor_sign() {
        let history = steady(14);
        let tonight = NightBiomarkers {
            skin_temp: Some(36.2), // well up on a 35.0 baseline
            ..history[0]
        };
        let v = symptom_signs(tonight, &history, "2026-09-14");
        assert_eq!(v["status"], "MINOR_SIGNS", "{v}");
    }

    #[test]
    fn the_classic_pattern_is_a_major_sign() {
        let history = steady(14);
        // fever, tachycardia, suppressed HRV, fast breathing — all at once
        let tonight = NightBiomarkers {
            skin_temp: Some(36.5),
            lowest_hr: Some(62.0),
            hrv_ms: Some(38.0),
            breath_rate: Some(18.0),
        };
        let v = symptom_signs(tonight, &history, "2026-09-14");
        assert_eq!(v["status"], "MAJOR_SIGNS", "{v}");
        let flagged: Vec<&str> = v["biomarkers"]
            .as_array()
            .unwrap()
            .iter()
            .filter(|b| b["indicatesSymptoms"] == true)
            .map(|b| b["type"].as_str().unwrap())
            .collect();
        assert_eq!(flagged.len(), 4, "{v}");
        // HRV must be flagged for falling, not rising
        let hrv = v["biomarkers"]
            .as_array()
            .unwrap()
            .iter()
            .find(|b| b["type"] == "AverageHrv")
            .unwrap();
        assert_eq!(hrv["reason"], "DECREASED");
    }

    /// The baseline must exclude tonight, or a sustained fever slowly becomes "normal".
    #[test]
    fn tonight_does_not_set_its_own_baseline() {
        let history = steady(14);
        let feverish = NightBiomarkers {
            skin_temp: Some(36.5),
            ..history[0]
        };
        let v = symptom_signs(feverish, &history, "2026-09-14");
        let temp = v["biomarkers"]
            .as_array()
            .unwrap()
            .iter()
            .find(|b| b["type"] == "TemperatureDeviation")
            .unwrap();
        assert_eq!(temp["indicatesSymptoms"], true, "{v}");
        // reported as a change from baseline, so the band straddles zero
        assert!(temp["upper"].as_f64().unwrap() < 1.0, "baseline must ignore tonight: {v}");
        assert!(temp["value"].as_f64().unwrap() > 1.0, "should read as +1.5 C, not 36.5: {v}");
    }
}
