import SwiftUI

enum PersonalDisplay {
    static func number(_ value: Double, metric: PersonalMetric) -> Double {
        switch metric {
        case .skinTemperature: return value * 1.8 + 32
        case .temperatureDeviation: return value * 1.8
        default: return value
        }
    }
    static func unit(_ metric: PersonalMetric) -> String {
        [.skinTemperature, .temperatureDeviation].contains(metric) ? "°F" : metric.unit
    }
    static func value(_ value: Double?, metric: PersonalMetric) -> String {
        guard let value, value.isFinite else { return "—" }
        if metric.unit == "h" { return PersonalChartStyle.duration(value) }
        let unit = unit(metric), converted = number(value, metric: metric)
        guard converted.isFinite else { return "—" }
        return converted.formatted(.number.precision(.fractionLength(["°F", "km"].contains(unit) ? 1 : 0))) + (unit.isEmpty ? "" : " " + unit)
    }
    static func sleepStory(_ night: PersonalNight?, goal: Double) -> String {
        guard let night, let hours = night.hours, hours.isFinite, goal.isFinite, goal > 0 else { return "Sleep duration unavailable" }
        let delta = hours - goal
        if abs(delta) < 1.0 / 6 { return "Within 10 minutes of your sleep goal" }
        return PersonalChartStyle.duration(abs(delta)) + (delta < 0 ? " below your sleep goal" : " above your sleep goal")
    }
    static func source(_ value: PersonalValue, metric: PersonalMetric) -> String {
        let estimate = [.steps, .energy, .distance].contains(metric) && value.identity.hasPrefix("direct-ring")
        return [value.source.rawValue, value.method, estimate ? "Estimated" : nil].compactMap { $0 }.joined(separator: " · ")
    }
}

struct PersonalScoreBadge: View {
    let score: Int?
    var body: some View {
        VStack(alignment: .trailing, spacing: 2) {
            Text(score.map(String.init) ?? "—").font(.title2.weight(.semibold)).monospacedDigit()
                .foregroundStyle(score.map { ScoreBand.forScore(Double($0)).color } ?? .secondary)
            Text("App score").font(.caption2).foregroundStyle(.secondary)
        }.accessibilityElement(children: .ignore)
            .accessibilityLabel(score.map { "App score, \($0) out of 100, \(ScoreBand.forScore(Double($0)).rawValue)" } ?? "App score unavailable")
    }
}

struct PersonalTopicRow: View {
    let kind: PersonalScoreKind
    let score: Int?
    let detail: String
    @Environment(\.dynamicTypeSize) private var textSize
    var body: some View {
        let layout = textSize.isAccessibilitySize ? AnyLayout(VStackLayout(alignment: .leading, spacing: 12)) : AnyLayout(HStackLayout(spacing: 14))
        layout {
            HStack(spacing: 14) {
            Image(systemName: kind == .activity ? "flame" : "waveform.path.ecg").font(.title2).foregroundStyle(.teal).frame(width: 28)
            VStack(alignment: .leading, spacing: 4) {
                Text(kind.rawValue).font(.headline).fixedSize(horizontal: false, vertical: true)
                Text(detail).font(.subheadline).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            }
            HStack(spacing: 10) {
            PersonalScoreBadge(score: score)
            Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
            }
        }.padding(.vertical, 8).frame(minHeight: 60).contentShape(Rectangle())
    }
}

struct PersonalMetricReadout: View {
    let title: String
    let value: String
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.title3.weight(.semibold)).monospacedDigit().fixedSize(horizontal: false, vertical: true)
        }.frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 6).accessibilityElement(children: .combine)
    }
}

struct PersonalSleepEssentials: View {
    let night: PersonalNight
    @Environment(\.dynamicTypeSize) private var textSize
    var body: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), alignment: .leading), count: textSize.isAccessibilitySize ? 1 : 3), alignment: .leading, spacing: 12) {
            ForEach([PersonalMetric.timeInBed, .efficiency, .latency]) { metric in
                PersonalMetricReadout(title: metric.title, value: PersonalDisplay.value(night.value(metric), metric: metric))
            }
        }
    }
}

struct PersonalFocusReport: View {
    let kind: PersonalScoreKind
    let day: PersonalDay
    let scores: PersonalDailyScores
    let days: [PersonalDay]
    let goals: PersonalGoals
    let isDemo: Bool
    @Environment(\.dynamicTypeSize) private var textSize
    private var score: Int? { kind == .activity ? scores.activity.score : scores.recovery.score }
    var body: some View {
        List {
            if isDemo {
                Section { Label("Demo · synthetic data", systemImage: "testtube.2").font(.caption).foregroundStyle(.secondary) }
            }
            Section {
                let header = textSize.isAccessibilitySize ? AnyLayout(VStackLayout(alignment: .leading, spacing: 12)) : AnyLayout(HStackLayout())
                header {
                    Text(day.date.formatted(date: .abbreviated, time: .omitted)).font(.subheadline)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    PersonalScoreBadge(score: score)
                }
                if kind == .activity {
                    let layout = textSize.isAccessibilitySize ? AnyLayout(VStackLayout(alignment: .leading, spacing: 12)) : AnyLayout(HStackLayout(alignment: .top, spacing: 20))
                    layout {
                        PersonalMetricReadout(title: "Steps", value: PersonalDisplay.value(day.value(.steps)?.value, metric: .steps))
                        PersonalMetricReadout(title: "Active energy", value: PersonalDisplay.value(day.value(.energy)?.value, metric: .energy))
                    }
                    if scores.activity.estimated { Label("Includes ring activity estimates", systemImage: "exclamationmark.circle").font(.caption).foregroundStyle(.secondary) }
                } else {
                    let layout = textSize.isAccessibilitySize ? AnyLayout(VStackLayout(alignment: .leading, spacing: 12)) : AnyLayout(HStackLayout(alignment: .top, spacing: 20))
                    layout {
                        PersonalMetricReadout(title: "HRV", value: PersonalDisplay.value(day.value(.hrv)?.value, metric: .hrv))
                        PersonalMetricReadout(title: "Resting heart rate", value: PersonalDisplay.value(day.value(.restingHR)?.value, metric: .restingHR))
                    }
                    if score == nil { Text("Building your baseline. Recovery needs at least 14 comparable days.").font(.subheadline).foregroundStyle(.secondary) }
                }
                NavigationLink("Score breakdown") { PersonalLiveScoreDetail(kind: kind, day: day, scores: scores) }
            }
            if kind == .activity {
                Section("Steps this week") { PersonalWeekChart(days: days, metric: .steps, goal: goals.steps, endingOn: day.date) }
                Section("Active energy") { PersonalWeekChart(days: days, metric: .energy, goal: goals.activeEnergy, endingOn: day.date) }
                Section("Movement") {
                    ForEach([PersonalMetric.distance, .totalEnergy]) { metric in
                        if let value = day.value(metric) { LabeledContent(metric.title, value: PersonalDisplay.value(value.value, metric: metric)) }
                    }
                    if day.value(.distance) == nil && day.value(.totalEnergy) == nil { Text("No additional movement measurements.").foregroundStyle(.secondary) }
                }
                Section("Workouts") {
                    if day.workouts.isEmpty { Text("No recorded workouts.").foregroundStyle(.secondary) }
                    ForEach(day.workouts) { workout in LabeledContent(workout.title, value: "\(Int(workout.minutes)) min · \(workout.start.formatted(date: .omitted, time: .shortened))") }
                }
            } else {
                Section("HRV this week") { PersonalWeekChart(days: days, metric: .hrv, goal: nil, endingOn: day.date) }
                Section("Resting heart rate") { PersonalWeekChart(days: days, metric: .restingHR, goal: nil, endingOn: day.date) }
                Section("Sleep this week") { PersonalWeekChart(days: days, metric: .sleep, goal: goals.sleepHours, endingOn: day.date) }
            }
            Section {
                DisclosureGroup("Sources & score information") {
                    Text("App scores are independent formulas, not official Oura scores or medical assessments.").font(.footnote)
                    ForEach(kind == .activity ? [PersonalMetric.steps, .energy, .distance, .totalEnergy] : [.hrv, .restingHR, .sleep]) { metric in
                        if let value = day.value(metric) { LabeledContent(metric.title, value: PersonalDisplay.source(value, metric: metric)).font(.caption) }
                    }
                    if kind == .recovery { Text(scores.recovery.explanation).font(.footnote) }
                }
            }
        }.navigationTitle(kind.rawValue).navigationBarTitleDisplayMode(.inline)
    }
}
