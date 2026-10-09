import Foundation

struct PersonalGoals: Codable, Equatable {
    var sleepHours = 8.0
    var steps = 8_000.0
    var activeEnergy = 400.0
    static func load() -> Self {
        guard let data = UserDefaults.standard.data(forKey: "personal.goals"),
              let value = try? JSONDecoder().decode(Self.self, from: data),
              value.sleepHours.isFinite, (4...12).contains(value.sleepHours),
              value.steps.isFinite, (1_000...30_000).contains(value.steps),
              value.activeEnergy.isFinite, (100...1_500).contains(value.activeEnergy) else { return Self() }
        return value
    }
    func save() { if let data = try? JSONEncoder().encode(self) { UserDefaults.standard.set(data, forKey: "personal.goals") } }
}

extension PersonalDay {
    // Original archive records stay in the historical cache, never in live scoring.
    var liveOnly: PersonalDay {
        var copy = self
        copy.archiveRecords = nil
        copy.values = values.filter { !$0.value.identity.hasPrefix("oura-account-export") }
        copy.values.removeValue(forKey: PersonalMetric.sleepScore.rawValue)
        copy.values.removeValue(forKey: PersonalMetric.readinessScore.rawValue)
        copy.values.removeValue(forKey: PersonalMetric.activityScore.rawValue)
        if let liveNight, !liveNight.identity.hasPrefix("oura-account-export") { copy.night = liveNight }
        else if copy.night?.identity.hasPrefix("oura-account-export") == true { copy.night = nil }
        copy.liveNight = nil
        return copy
    }
}

struct PersonalScoreComponent: Identifiable {
    var title: String
    var score: Double?
    var weight: Double
    var detail: String
    var id: String { title }
}
struct PersonalLiveScore {
    var score: Int?
    var components: [PersonalScoreComponent]
    var explanation: String
    var estimated = false
    var coverage: Double { components.filter { $0.score != nil }.reduce(0) { $0 + $1.weight } }
}
enum PersonalLiveScoring {
    static func sleep(_ day: PersonalDay, goals: PersonalGoals) -> PersonalLiveScore {
        let night = day.liveOnly.night
        let hours = night?.hours
        let efficiency = night?.value(.efficiency)
        let wake = night?.value(.wakeAfterSleep)
        func finite(_ value: Double?) -> Double? { value.flatMap { $0.isFinite && $0 >= 0 ? $0 : nil } }
        let durationScore = finite(hours).flatMap { goals.sleepHours > 0 ? min(100, $0 / goals.sleepHours * 100) : nil }
        let continuity = finite(wake).flatMap { awake -> Double? in
            guard let hours, hours > 0 else { return nil }
            return max(0, min(100, 100 * (1 - awake / (hours + awake))))
        }
        let parts = [
            PersonalScoreComponent(title: "Sleep goal", score: durationScore, weight: 0.65, detail: "Recorded sleep ÷ your \(goals.sleepHours.formatted()) h goal, capped at 100."),
            PersonalScoreComponent(title: "Efficiency", score: finite(efficiency).map { min(100, $0) }, weight: 0.25, detail: "Percentage of the recorded bed window spent asleep."),
            PersonalScoreComponent(title: "Continuity", score: continuity, weight: 0.10, detail: "Sleep ÷ sleep plus recorded awake time after onset. Requires complete stages.")
        ]
        return combine(parts, minimum: 0.85, explanation: "Our experimental goal-based formula: 65% sleep goal, 25% efficiency, 10% continuity. Missing parts are excluded and available weights renormalize; at least 85% coverage is required. Not Oura’s score or a clinical assessment. Deep, REM and light sleep are shown as measurements, not judged against invented targets.")
    }
    static func activity(_ day: PersonalDay, goals: PersonalGoals) -> PersonalLiveScore {
        let live = day.liveOnly
        let steps = live.value(.steps), energy = live.value(.energy)
        func goalScore(_ value: Double?, goal: Double) -> Double? {
            guard let value, value.isFinite, value >= 0, goal.isFinite, goal > 0 else { return nil }
            return min(100, value / goal * 100)
        }
        let parts = [
            PersonalScoreComponent(title: "Step goal", score: goalScore(steps?.value, goal: goals.steps), weight: 0.70, detail: "Daily steps ÷ your \(Int(goals.steps)) step goal, capped at 100."),
            PersonalScoreComponent(title: "Active energy goal", score: goalScore(energy?.value, goal: goals.activeEnergy), weight: 0.30, detail: "Active energy ÷ your \(Int(goals.activeEnergy)) kcal goal, capped at 100.")
        ]
        var result = combine(parts, minimum: 0.60, explanation: "Our goal-progress formula: 70% steps, 30% active energy. Missing parts are excluded and available weights renormalize; at least 60% coverage is required. These editable goals are preferences, not medical recommendations. Today’s progress grows during the day; this is not Oura’s Activity score.")
        result.estimated = [steps, energy].compactMap { $0 }.contains { $0.identity.hasPrefix("direct-ring") }
        if result.estimated { result.explanation += " Direct-ring steps and active energy currently come from activity-intensity estimates, not verified step counts/calorie measurements." }
        return result
    }
    private static func combine(_ parts: [PersonalScoreComponent], minimum: Double, explanation: String) -> PersonalLiveScore {
        let available = parts.filter { $0.score != nil }
        let weight = available.reduce(0) { $0 + $1.weight }
        let score = weight >= minimum ? Int((available.reduce(0) { $0 + ($1.score ?? 0) * $1.weight } / weight).rounded()) : nil
        return PersonalLiveScore(score: score, components: parts, explanation: explanation)
    }
}

struct PersonalDailyScores {
    var sleep: PersonalLiveScore
    var activity: PersonalLiveScore
    var recovery: PersonalRecovery.Result
}
struct PersonalPlotPoint {
    var time: Date
    var value: Double
    var segment: Int
    var coverage: ClosedRange<Date>
}
struct PersonalNightCharts {
    var stages: [PersonalStage]
    var heartRate: [PersonalPlotPoint]
    var hrv: [PersonalPlotPoint]
    // Segment ORIGINAL timestamps before display reduction; a chart must not bridge missing readings.
    // This is a display continuity rule, not a physiological inference.
    static func plotPoints(_ points: [PersonalPoint], limit: Int = 360) -> [PersonalPlotPoint] {
        let sorted = points.filter { $0.time.timeIntervalSince1970.isFinite && $0.value.isFinite && $0.value > 0 }.sorted { $0.time < $1.time }
        var groups: [[PersonalPoint]] = []
        for point in sorted {
            if let last = groups.last?.last, point.time.timeIntervalSince(last.time) <= 15 * 60 {
                groups[groups.count - 1].append(point)
            } else { groups.append([point]) }
        }
        var metadata: [Date: (Int, ClosedRange<Date>)] = [:]
        for (segment, group) in groups.enumerated() {
            let coverage = group.first!.time...group.last!.time
            for point in group { metadata[point.time] = (segment, coverage) }
        }
        return boundedHeartRate(sorted, limit: limit).compactMap { point in
            guard let (segment, coverage) = metadata[point.time] else { return nil }
            return PersonalPlotPoint(time: point.time, value: point.value, segment: segment, coverage: coverage)
        }
    }
    static func inspectedPoint(_ selected: Date, points: [PersonalPlotPoint]) -> PersonalPlotPoint? {
        points.filter { $0.coverage.contains(selected) || abs($0.time.timeIntervalSince(selected)) <= 60 }
            .min { abs($0.time.timeIntervalSince(selected)) < abs($1.time.timeIntervalSince(selected)) }
    }
    // Display-only min/max buckets preserve peaks; originals remain available in cache.
    static func boundedHeartRate(_ points: [PersonalPoint], limit: Int = 360) -> [PersonalPoint] {
        let sorted = points.filter { $0.time.timeIntervalSince1970.isFinite && $0.value.isFinite && $0.value > 0 }.sorted { $0.time < $1.time }
        guard sorted.count > limit, limit >= 4 else { return sorted }
        let size = Int(ceil(Double(sorted.count) / Double((limit - 2) / 2)))
        var result = [sorted[0]]
        for start in stride(from: 1, to: sorted.count - 1, by: size) {
            let bucket = sorted[start..<min(sorted.count - 1, start + size)]
            if let lo = bucket.min(by: { $0.value < $1.value }), let hi = bucket.max(by: { $0.value < $1.value }) {
                result += lo.time == hi.time ? [lo] : (lo.time <= hi.time ? [lo, hi] : [hi, lo])
            }
        }
        result.append(sorted[sorted.count - 1])
        return result
    }
}
struct PersonalLiveSnapshot {
    var days: [PersonalDay] = []
    var byDate: [Date: PersonalDay] = [:]
    var scores: [Date: PersonalDailyScores] = [:]
    var nights: [Date: PersonalNightCharts] = [:]
    static func build(_ stored: [PersonalDay], preferences: PersonalPreferences, goals: PersonalGoals) -> Self {
        let days = stored.map { $0.liveOnly.enforcingSleepInput(preferences.resolvedSleepInput) }.filter { !$0.values.isEmpty || $0.night != nil || !$0.workouts.isEmpty }.sorted { $0.date < $1.date }
        var result = Self(days: days)
        for day in days {
            result.byDate[day.date] = day
            result.scores[day.date] = PersonalDailyScores(sleep: PersonalLiveScoring.sleep(day, goals: goals), activity: PersonalLiveScoring.activity(day, goals: goals), recovery: PersonalRecovery.calculate(day: day, history: days, preferences: preferences))
            if let night = day.night { result.nights[day.date] = PersonalNightCharts(stages: night.chartStages, heartRate: PersonalNightCharts.plotPoints(night.heartRate), hrv: PersonalNightCharts.plotPoints(night.hrvSeries ?? [])) }
        }
        return result
    }
}
