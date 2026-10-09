import Foundation
import SwiftData

enum PersonalSource: String, Codable, CaseIterable, Identifiable, Hashable {
    case ring = "Oura Ring", watch = "Apple Watch"
    var id: String { rawValue }
    var other: PersonalSource { self == .ring ? .watch : .ring }
}
enum PersonalMetric: String, Codable, CaseIterable, Identifiable, Hashable {
    case sleep, restingHR, hrv, steps, energy, workouts
    case deepSleep, remSleep, lightSleep, awake, efficiency, awakenings, latency
    case averageHR, respiratoryRate, oxygen, skinTemperature, totalEnergy, distance
    case sleepScore, readinessScore, activityScore, temperatureDeviation, stress, restored, cardiovascularAge
    case timeInBed, wakeAfterSleep, restlessPeriods, breathingDisturbances, vo2Max
    var id: String { rawValue }
    var title: String {
        switch self {
        case .sleep: return "Sleep"
        case .restingHR: return "Resting heart rate"
        case .hrv: return "HRV"
        case .steps: return "Steps"
        case .energy: return "Active energy"
        case .workouts: return "Workouts"
        case .deepSleep: return "Deep sleep"
        case .remSleep: return "REM sleep"
        case .lightSleep: return "Light / core sleep"
        case .awake: return "Awake during sleep window"
        case .efficiency: return "Sleep efficiency"
        case .awakenings: return "Detected awakenings"
        case .latency: return "Time to fall asleep"
        case .averageHR: return "Average overnight heart rate"
        case .respiratoryRate: return "Respiratory rate"
        case .oxygen: return "Blood oxygen"
        case .skinTemperature: return "Skin temperature"
        case .totalEnergy: return "Total energy"
        case .distance: return "Walking equivalent distance"
        case .sleepScore: return "Oura sleep score · imported"
        case .readinessScore: return "Oura readiness · imported"
        case .activityScore: return "Oura activity score · imported"
        case .temperatureDeviation: return "Temperature deviation"
        case .stress: return "High stress time · imported"
        case .restored: return "Restored time · imported"
        case .cardiovascularAge: return "Cardiovascular age · imported"
        case .timeInBed: return "Time in bed"
        case .wakeAfterSleep: return "Awake after falling asleep"
        case .restlessPeriods: return "Restless periods · imported"
        case .breathingDisturbances: return "Breathing disturbance index · imported"
        case .vo2Max: return "VO₂ max · imported"
        }
    }
    var defaultSource: PersonalSource {
        [.steps, .energy, .workouts].contains(self) ? .watch : .ring
    }
    var unit: String {
        switch self {
        case .sleep: return "h"
        case .restingHR: return "bpm"
        case .hrv: return "ms"
        case .steps, .workouts: return ""
        case .energy: return "kcal"
        case .deepSleep, .remSleep, .lightSleep, .awake, .stress, .restored: return "h"
        case .efficiency, .oxygen: return "%"
        case .awakenings, .sleepScore, .readinessScore, .activityScore: return ""
        case .latency: return "min"
        case .averageHR: return "bpm"
        case .respiratoryRate: return "breaths/min"
        case .skinTemperature, .temperatureDeviation: return "°C"
        case .totalEnergy: return "kcal"
        case .distance: return "km"
        case .cardiovascularAge: return "years"
        case .timeInBed, .wakeAfterSleep: return "h"
        case .restlessPeriods, .breathingDisturbances: return ""
        case .vo2Max: return "mL/kg/min"
        }
    }
    var sleepMetric: Bool { [.sleep, .deepSleep, .remSleep, .lightSleep, .awake, .efficiency, .awakenings, .latency, .timeInBed, .wakeAfterSleep, .restlessPeriods].contains(self) }
}
struct PersonalValue: Codable, Equatable {
    var value: Double
    var source: PersonalSource
    // Includes exact HealthKit bundle/device identity, or ring serial, and HRV method.
    var identity: String
    var method: String?
}
struct PersonalStage: Codable, Identifiable {
    var start: Date
    var end: Date
    var label: String
    var id: Date { start }
}
struct PersonalPoint: Codable, Identifiable {
    var time: Date
    var value: Double
    var id: Date { time }
}
struct PersonalNight: Codable {
    var start: Date
    var end: Date
    var source: PersonalSource
    var identity: String
    var hours: Double?
    var restorativeHours: Double?
    var stages: [PersonalStage]
    var heartRate: [PersonalPoint]
    var hrvSeries: [PersonalPoint]? = nil
    var hrvMethod: String? = nil
    // Optional additions keep existing local caches readable.
    var reported: [String: Double]? = nil
    var bedStart: Date? = nil
    var bedEnd: Date? = nil
    var provenance: String? = nil
    // Compact chart marks only; original samples remain intact for all metrics.
    var chartStages: [PersonalStage] {
        var result: [PersonalStage] = []
        for stage in stages.sorted(by: { $0.start < $1.start }) {
            if let last = result.last, last.label == stage.label, last.end == stage.start {
                result[result.count - 1].end = stage.end
            } else { result.append(stage) }
        }
        return result
    }
    var asleepStart: Date? {
        if let first = stages.filter({ ["Deep", "Core", "REM", "Asleep"].contains($0.label) && $0.end > $0.start }).map(\.start).min() { return first }
        if let bedStart, let latency = reported?[PersonalMetric.latency.rawValue], latency >= 0 {
            let onset = bedStart.addingTimeInterval(latency * 60)
            return onset < end ? onset : nil
        }
        return nil
    }
    var asleepEnd: Date? { stages.filter { ["Deep", "Core", "REM", "Asleep"].contains($0.label) && $0.end > $0.start }.map(\.end).max() }
    var longestRecordedSleepHours: Double? {
        let sleep = stages.filter { ["Deep", "Core", "REM", "Asleep"].contains($0.label) && $0.end > $0.start }
            .map { (max(start, $0.start), min(end, $0.end)) }.filter { $0.1 > $0.0 }.sorted { $0.0 < $1.0 }
        guard let first = sleep.first else { return nil }
        var a = first.0, b = first.1, longest = b.timeIntervalSince(a)
        for interval in sleep.dropFirst() {
            if interval.0 <= b { b = max(b, interval.1) }
            else { longest = max(longest, b.timeIntervalSince(a)); a = interval.0; b = interval.1 }
        }
        return max(longest, b.timeIntervalSince(a)) / 3600
    }
    var sleepWindowMidpoint: Date? {
        guard coverage >= 0.95, let onset = asleepStart, let wake = asleepEnd, wake > onset else { return nil }
        return onset.addingTimeInterval(wake.timeIntervalSince(onset) / 2)
    }
    var coverage: Double { min(1, PersonalAssembler.unionHours(stages.map { ($0.start, $0.end) }) * 3600 / max(1, end.timeIntervalSince(start))) }
    func stageHours(_ label: String) -> Double? {
        guard !stages.isEmpty, coverage >= 0.95 else { return nil }
        if label != "Awake", stages.contains(where: { $0.label == "Asleep" }) { return nil }
        return PersonalAssembler.unionHours(stages.filter { $0.label == label }.map { ($0.start, $0.end) })
    }
    var awakeningSpans: [PersonalStage] {
        guard let onset = asleepStart, let wake = asleepEnd else { return [] }
        let rows = stages.filter { $0.label == "Awake" && $0.end > onset && $0.start < wake }.sorted { $0.start < $1.start }
        var merged: [PersonalStage] = []
        for row in rows {
            let clipped = PersonalStage(start: max(row.start, onset), end: min(row.end, wake), label: "Awake")
            if let last = merged.last, clipped.start <= last.end {
                merged[merged.count - 1].end = max(last.end, clipped.end)
            } else { merged.append(clipped) }
        }
        return merged
    }
    func value(_ metric: PersonalMetric) -> Double? {
        if let value = reported?[metric.rawValue] { return value }
        switch metric {
        case .sleep: return hours
        case .deepSleep: return stageHours("Deep")
        case .remSleep: return stageHours("REM")
        case .lightSleep: return stageHours("Core")
        case .awake: return stageHours("Awake")
        case .efficiency:
            guard let hours, hours.isFinite, hours >= 0, let bedStart, let bedEnd, bedEnd > bedStart,
                  hours * 3600 <= bedEnd.timeIntervalSince(bedStart) + 1 else { return nil }
            return min(100, hours * 3600 / bedEnd.timeIntervalSince(bedStart) * 100)
        case .awakenings: return coverage >= 0.95 ? Double(awakeningSpans.count) : nil
        case .latency:
            guard let bedStart, let asleepStart, asleepStart >= bedStart else { return nil }
            let seconds = asleepStart.timeIntervalSince(bedStart)
            if source == .ring {
                // Missing leading epochs must not be mistaken for time awake.
                let awake = stages.filter { $0.label == "Awake" }.map { (max(bedStart, $0.start), min(asleepStart, $0.end)) }
                let covered = PersonalAssembler.unionHours(awake) * 3600
                guard covered >= seconds - 1 else { return nil }
            }
            return seconds / 60
        case .averageHR: return heartRate.isEmpty ? nil : heartRate.map(\.value).reduce(0, +) / Double(heartRate.count)
        case .timeInBed:
            guard let bedStart, let bedEnd, bedEnd > bedStart else { return nil }
            return bedEnd.timeIntervalSince(bedStart) / 3600
        case .wakeAfterSleep: return coverage >= 0.95 ? PersonalAssembler.unionHours(awakeningSpans.map { ($0.start, $0.end) }) : nil
        default: return nil
        }
    }
}
struct PersonalWorkout: Codable, Identifiable {
    var id: String
    var start: Date
    var minutes: Double
    var title: String
    var source: PersonalSource
}
struct PersonalDay: Codable, Identifiable {
    var date: Date
    var values: [String: PersonalValue] = [:]
    var night: PersonalNight?
    // Optional for old-cache compatibility; preserves partial live nights when an
    // archive supplies a complete historical night for the same calendar day.
    var liveNight: PersonalNight? = nil
    var workouts: [PersonalWorkout] = []
    var archiveRecords: [PersonalArchiveRecord]? = nil
    var id: Date { date }
    func value(_ metric: PersonalMetric) -> PersonalValue? { values[metric.rawValue] }
}
@Model final class PersonalCachedDay {
    @Attribute(.unique) var dayKey: String
    var payload: Data
    var refreshedAt: Date
    init(dayKey: String, payload: Data) {
        self.dayKey = dayKey; self.payload = payload; refreshedAt = Date()
    }
}
struct PersonalPreferences: Codable, Equatable {
    var priorities: [String: PersonalSource] = [:]
    var rhrWeight = 0.3
    var hrvWeight = 0.3
    var sleepWeight = 0.3
    var stagesWeight = 0.1
    func source(_ metric: PersonalMetric) -> PersonalSource { priorities[metric.rawValue] ?? metric.defaultSource }
    static func load() -> Self {
        guard let data = UserDefaults.standard.data(forKey: "personal.preferences"),
              let value = try? JSONDecoder().decode(Self.self, from: data) else { return Self() }
        return value
    }
    func save() { if let data = try? JSONEncoder().encode(self) { UserDefaults.standard.set(data, forKey: "personal.preferences") } }
}

enum PersonalRecovery {
    struct Result { var score: Int?; var coverage: Double; var explanation: String }
    // Baseline excludes today, uses preceding 30 calendar days, and requires 14 valid days.
    static func calculate(day: PersonalDay, history: [PersonalDay], preferences p: PersonalPreferences) -> Result {
        let start = Calendar.current.date(byAdding: .day, value: -30, to: day.date)!
        let past = history.filter { $0.date >= start && $0.date < day.date }
        var weighted = 0.0, available = 0.0
        let weights = [p.rhrWeight, p.hrvWeight, p.sleepWeight, p.stagesWeight].map { $0.isFinite ? max(0, $0) : 0 }
        let total = weights.reduce(0, +)
        func component(_ value: Double?, baseline: [Double], weight: Double, lowerIsBetter: Bool) {
            guard weight > 0, let value, value.isFinite, value > 0 else { return }
            let valid = baseline.filter { $0.isFinite && $0 > 0 }
            guard valid.count >= 14 else { return }
            let mean = valid.reduce(0, +) / Double(valid.count)
            let ratio = lowerIsBetter ? mean / value : value / mean
            // Baseline = 80; a 20% relative improvement reaches 100. Deliberately capped.
            weighted += min(100, max(0, 80 + 100 * (ratio - 1))) * weight
            available += weight
        }
        for (metric, weight, lower) in [(PersonalMetric.restingHR, weights[0], true), (.hrv, weights[1], false), (.sleep, weights[2], false)] {
            guard let current = day.value(metric) else { continue }
            let baseline = past.compactMap { previous -> Double? in
                guard let v = previous.value(metric), v.identity == current.identity, v.method == current.method else { return nil }
                return v.value
            }
            component(current.value, baseline: baseline, weight: weight, lowerIsBetter: lower)
        }
        if let night = day.night {
            let baseline = past.compactMap { previous -> Double? in
                guard let n = previous.night, n.identity == night.identity else { return nil }
                return n.restorativeHours
            }
            component(night.restorativeHours, baseline: baseline, weight: weights[3], lowerIsBetter: false)
        }
        let coverage = total > 0 ? available / total : 0
        guard available > 0, coverage >= 0.6 else {
            return Result(score: nil, coverage: coverage, explanation: "Needs 14 comparable days in the preceding 30 days and at least 60% of configured weight.")
        }
        return Result(score: Int((weighted / available).rounded()), coverage: coverage,
                      explanation: "Your baseline is 80. Coverage: \(Int((coverage * 100).rounded()))%. Your formula, not Oura Readiness.")
    }
}
