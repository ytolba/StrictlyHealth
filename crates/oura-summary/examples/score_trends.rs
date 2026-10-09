//! Validate the literature-based sleep score against Oura's own, over a trends export.
//!
//! The two are computed from different things: ours from published recommendation
//! bands, Oura's from whatever Oura does. Agreement is reassuring, but the disagreements
//! are the point — they say where the published consensus and the vendor part company.
//!
//! ```sh
//! cargo run -p oura-summary --example score_trends -- ~/deving/random/open_oura/local/trends.csv 40
//! ```
//! (second argument: the wearer's age, for the duration bands)

use std::collections::HashMap;

use oura_summary::sleep_score::{score_night, NightInput};

fn main() {
    let mut args = std::env::args().skip(1);
    let path = args.next().unwrap_or_else(|| {
        eprintln!("usage: score_trends <trends.csv> [age]");
        std::process::exit(2);
    });
    let age: f64 = args.next().and_then(|v| v.parse().ok()).unwrap_or(40.0);

    let text = std::fs::read_to_string(&path).expect("reading the trends CSV");
    let mut lines = text.lines();
    let header: Vec<&str> = lines.next().expect("header row").split(',').collect();
    let index: HashMap<&str, usize> = header
        .iter()
        .enumerate()
        .map(|(i, name)| (name.trim(), i))
        .collect();
    let column = |row: &[&str], name: &str| -> Option<f64> {
        let value = row.get(*index.get(name)?)?.trim();
        (!value.is_empty()).then(|| value.parse().ok())?
    };

    // Baselines come from the export itself: the wearer's own mean and SD across every
    // night present, which is what the score's physiology component expects.
    let rows: Vec<Vec<&str>> = lines
        .filter(|line| !line.trim().is_empty())
        .map(|line| line.split(',').collect())
        .collect();
    let stats = |name: &str| -> Option<(f64, f64)> {
        let values: Vec<f64> = rows.iter().filter_map(|row| column(row, name)).collect();
        if values.len() < 30 {
            return None;
        }
        let mean = values.iter().sum::<f64>() / values.len() as f64;
        let sd = (values.iter().map(|v| (v - mean).powi(2)).sum::<f64>()
            / values.len() as f64)
            .sqrt();
        Some((mean, sd))
    };
    let rhr_baseline = stats("Lowest Resting Heart Rate");
    let hrv_baseline = stats("Average HRV");

    let mut pairs: Vec<(f64, f64)> = Vec::new();
    for row in &rows {
        let (Some(oura), Some(total_sleep_s)) =
            (column(row, "Sleep Score"), column(row, "Total Sleep Duration"))
        else {
            continue;
        };
        let bedtime_s = column(row, "Total Bedtime");
        let efficiency = column(row, "Sleep Efficiency");
        let ours = score_night(NightInput {
            asleep_min: Some(total_sleep_s / 60.0),
            efficiency_pct: efficiency,
            onset_latency_min: column(row, "Sleep Latency").map(|s| s / 60.0),
            waso_min: column(row, "Awake Time").map(|s| s / 60.0),
            awakenings: None, // the trends export does not carry an awakening count
            deep_pct: column(row, "Deep Sleep Duration")
                .zip(bedtime_s)
                .map(|(deep, bed)| deep / bed * 100.0),
            rem_pct: column(row, "REM Sleep Duration")
                .zip(bedtime_s)
                .map(|(rem, bed)| rem / bed * 100.0),
            rhr: column(row, "Lowest Resting Heart Rate"),
            rhr_baseline,
            hrv_ms: column(row, "Average HRV"),
            hrv_baseline,
            age,
        });
        if let Some(ours) = ours["score"].as_f64() {
            pairs.push((oura, ours));
        }
    }

    if pairs.len() < 2 {
        eprintln!("not enough scoreable nights in {path}");
        std::process::exit(1);
    }
    let n = pairs.len() as f64;
    let mean_oura = pairs.iter().map(|p| p.0).sum::<f64>() / n;
    let mean_ours = pairs.iter().map(|p| p.1).sum::<f64>() / n;
    let cov: f64 = pairs
        .iter()
        .map(|(a, b)| (a - mean_oura) * (b - mean_ours))
        .sum::<f64>();
    let var_oura: f64 = pairs.iter().map(|(a, _)| (a - mean_oura).powi(2)).sum();
    let var_ours: f64 = pairs.iter().map(|(_, b)| (b - mean_ours).powi(2)).sum();
    let r = cov / (var_oura.sqrt() * var_ours.sqrt());
    let mut differences: Vec<f64> = pairs.iter().map(|(a, b)| b - a).collect();
    differences.sort_by(f64::total_cmp);
    let percentile = |p: f64| differences[((differences.len() as f64 * p) as usize).min(differences.len() - 1)];

    println!("nights scored          {}", pairs.len());
    println!("mean Oura score        {mean_oura:.1}");
    println!("mean literature score  {mean_ours:.1}");
    println!("correlation r          {r:.3}   (r² {:.3})", r * r);
    println!(
        "ours − Oura            median {:+.0}, p10 {:+.0}, p90 {:+.0}",
        percentile(0.5),
        percentile(0.1),
        percentile(0.9)
    );
    let within = |limit: f64| {
        100.0 * differences.iter().filter(|d| d.abs() <= limit).count() as f64 / n
    };
    println!("agreement              {:.0}% within 10 pts, {:.0}% within 5", within(10.0), within(5.0));
}
