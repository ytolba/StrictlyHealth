import SwiftUI
import Charts

enum SleepReportFields {
    static let contributors = [("total_sleep", "Total sleep"), ("efficiency", "Efficiency"), ("restfulness", "Restfulness"), ("rem_sleep", "REM sleep"), ("deep_sleep", "Deep sleep"), ("latency", "Latency"), ("timing", "Timing")]
    static func contributor(_ key: String, records: [PersonalArchiveRecord]) -> Double? {
        for record in records where record.table == "dailysleep" {
            if let value = record.number("contributors_" + key) ?? record.number("contributors." + key), (0...100).contains(value) { return value }
            if let raw = record.fields["contributors"], let data = raw.data(using: .utf8), let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let value = (object[key] as? NSNumber)?.doubleValue, value.isFinite, (0...100).contains(value) { return value }
        }
        return nil
    }
    static func sleepRecords(_ day: PersonalDay) -> [PersonalArchiveRecord] {
        (day.archiveRecords ?? []).filter { $0.table.contains("sleep") || $0.table == "dailyspo2" }
    }
}

struct PersonalSleepReport: View {
    let day: PersonalDay
    var summary: PersonalDailyScores? = nil
    var charts: PersonalNightCharts? = nil
    var days: [PersonalDay] = []
    var goals = PersonalGoals()
    @Environment(\.dynamicTypeSize) private var textSize
    private let physiology: [PersonalMetric] = [.restingHR, .hrv, .respiratoryRate, .oxygen, .skinTemperature, .temperatureDeviation, .breathingDisturbances]
    var body: some View {
        let result = summary?.sleep ?? PersonalLiveScoring.sleep(day, goals: goals)
        ScrollViewReader { scroll in
        List {
            if ProcessInfo.processInfo.arguments.contains("--demo-dashboard") { Section { Label("Demo · synthetic data", systemImage: "testtube.2").font(.caption) } }
            Section {
                if let summary {
                    NavigationLink { PersonalLiveScoreDetail(kind: .sleep, day: day, scores: summary) } label: { header(score: result.score) }
                        .accessibilityHint("Opens the sleep score breakdown")
                } else { header(score: result.score) }
                if let night = day.night {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(PersonalChartStyle.duration(night.hours)).font(.largeTitle.weight(.semibold)).monospacedDigit()
                        Text("\(night.asleepStart.map { $0.formatted(date: .omitted, time: .shortened) } ?? "Onset unknown") → \(night.asleepEnd.map { $0.formatted(date: .omitted, time: .shortened) } ?? "Wake unknown")").font(.subheadline).monospacedDigit()
                    }.padding(.vertical, 6)
                    PersonalSleepEssentials(night: night).id("sleep-essentials")
                    if let prepared = charts, !prepared.stages.isEmpty { PersonalStageChart(night: night, stages: prepared.stages) }
                    else if !night.stages.isEmpty { PersonalStageChart(night: night, stages: night.chartStages) }
                    else { Text("Sleep stages unavailable").foregroundStyle(.secondary) }
                    Text(PersonalDisplay.sleepStory(night, goal: goals.sleepHours)).font(.subheadline).foregroundStyle(.secondary)
                } else { Text("No sleep session for this day. Sync your ring or connect Apple Health.").foregroundStyle(.secondary) }
            }
            if let night = day.night {
                Section("Sleep continuity") {
                    LabeledContent("Longest recorded sleep stretch", value: PersonalChartStyle.duration(night.longestRecordedSleepHours))
                    time("Sleep-window midpoint", night.sleepWindowMidpoint)
                }.id("sleep-continuity")
                Section("Your sleep rhythm · 7 nights") {
                    if let rhythm = PersonalSleepRhythm.calculate(days: days, endingOn: day.date, night: night, goal: goals.sleepHours) {
                        LabeledContent("Typical bedtime variation", value: "\(Int(rhythm.bedtimeVariationMinutes.rounded())) min").id("sleep-rhythm")
                        LabeledContent("Typical sleep", value: PersonalChartStyle.duration(rhythm.medianSleepHours))
                        LabeledContent("Sleep goal met", value: "\(rhythm.goalNights) of \(rhythm.nights) recorded nights")
                    } else {
                        Text("Needs at least 3 recorded nights from the same sleep source and device.").foregroundStyle(.secondary)
                    }
                }
                Section("Sleep stages") {
                    stage("Deep", metric: .deepSleep, color: .indigo, night: night)
                    stage("REM", metric: .remSleep, color: .cyan, night: night)
                    stage("Light", metric: .lightSleep, color: .blue, night: night)
                    LabeledContent("Awake", value: PersonalDisplay.value(night.value(.awake), metric: .awake))
                }
                Section("Timing") {
                    time("In bed", night.bedStart)
                    time("Fell asleep", night.asleepStart)
                    time("Last sleep ended", night.asleepEnd)
                    time("Out of bed", night.bedEnd)
                }
                Section("Awakenings") {
                    LabeledContent("Detected awakenings", value: PersonalDisplay.value(night.value(.awakenings), metric: .awakenings))
                    let spans = night.awakeningSpans
                    if spans.isEmpty { Text(night.coverage >= 0.95 ? "No recorded awakenings" : "Not enough stage data").foregroundStyle(.secondary) }
                    ForEach(Array(spans.enumerated()), id: \.offset) { _, span in
                        LabeledContent("\(span.start.formatted(date: .omitted, time: .shortened))–\(span.end.formatted(date: .omitted, time: .shortened))", value: String(format: "%.1f min", span.end.timeIntervalSince(span.start) / 60))
                    }
                    LabeledContent("Awake after falling asleep", value: PersonalDisplay.value(night.value(.wakeAfterSleep), metric: .wakeAfterSleep))
                    if let value = night.value(.restlessPeriods) { LabeledContent("Restless periods", value: PersonalDisplay.value(value, metric: .restlessPeriods)) }
                }
                Section("Overnight heart rate") {
                    if night.heartRate.isEmpty { Text("No overnight readings").foregroundStyle(.secondary) }
                    else {
                        let points = charts?.heartRate ?? PersonalNightCharts.plotPoints(night.heartRate)
                        let layout = textSize.isAccessibilitySize ? AnyLayout(VStackLayout(alignment: .leading, spacing: 12)) : AnyLayout(HStackLayout(alignment: .top, spacing: 20))
                        layout {
                            PersonalMetricReadout(title: "Lowest", value: PersonalDisplay.value(points.map(\.value).min(), metric: .averageHR))
                            PersonalMetricReadout(title: "Average", value: PersonalDisplay.value(night.value(.averageHR), metric: .averageHR))
                        }
                        PersonalHeartChart(points: points, start: night.start, end: night.end)
                    }
                }
                if let prepared = charts, !prepared.hrv.isEmpty {
                    Section("Overnight HRV · \(night.hrvMethod ?? "method unknown")") {
                        PersonalHeartChart(points: prepared.hrv, start: night.start, end: night.end, unit: "ms", color: .indigo)
                    }
                }
            }
            Section("Sleep this week") { PersonalWeekChart(days: days, metric: .sleep, goal: goals.sleepHours, endingOn: day.date) }
            Section("Daily physiology") {
                let available = physiology.filter { day.value($0) != nil }
                if available.isEmpty { Text("No daily measurements").foregroundStyle(.secondary) }
                ForEach(available) { metric in
                    if let value = day.value(metric) { LabeledContent(metric.title, value: PersonalDisplay.value(value.value, metric: metric)) }
                }
            }.id("sleep-physiology")
            Section {
                DisclosureGroup("Sources & sleep information") {
                    if let night = day.night {
                        Text(night.provenance ?? night.source.rawValue).font(.footnote)
                        Text("Stage coverage: \(Int(night.coverage * 100))%. Unknown intervals are gaps. Awake episodes are not clinically measured arousals.").font(.footnote)
                        time("Recorded window starts", night.start)
                        time("Recorded window ends", night.end)
                        Text("Time in bed is the recorded bed window. Efficiency is recorded sleep ÷ time in bed. Time to fall asleep needs a known bed start and sleep onset; missing leading ring epochs are not counted as awake.").font(.footnote)
                        Text("The longest stretch joins adjacent asleep stages; awake periods and data gaps break it. Midpoint is halfway between first and last sleep. Bedtime variation is the median distance from the week's typical onset; nights use one source/device. Typical sleep is a median, and goal counts use your chosen sleep goal.").font(.footnote)
                    }
                    ForEach(physiology) { metric in
                        if let value = day.value(metric) { LabeledContent(metric.title, value: PersonalDisplay.source(value, metric: metric)).font(.caption) }
                    }
                    Text("Daily physiology is not necessarily measured during this sleep window. Missing measurements are not zero.").font(.footnote)
                    Text(result.explanation).font(.footnote)
                    Text("Score coverage: \(Int(result.coverage * 100))%. Live scores exclude imported Oura results.").font(.caption)
                }
            }
        }.navigationTitle("Sleep").navigationBarTitleDisplayMode(.inline)
            .task {
                #if DEBUG
                if ProcessInfo.processInfo.arguments.contains("--demo-dashboard") {
                    // Let the native List settle before a screenshot-only scroll.
                    try? await Task.sleep(for: .milliseconds(300))
                    if ProcessInfo.processInfo.arguments.contains("--preview-sleep-insights") { scroll.scrollTo("sleep-continuity", anchor: .top) }
                    if ProcessInfo.processInfo.arguments.contains("--preview-sleep-physiology") { scroll.scrollTo("sleep-physiology", anchor: .top) }
                    if ProcessInfo.processInfo.arguments.contains("--preview-sleep-essentials") { scroll.scrollTo("sleep-essentials", anchor: .top) }
                    if ProcessInfo.processInfo.arguments.contains("--preview-sleep-rhythm") { scroll.scrollTo("sleep-rhythm", anchor: .top) }
                }
                #endif
            }
        }
    }
    private func header(score: Int?) -> some View {
        let layout = textSize.isAccessibilitySize ? AnyLayout(VStackLayout(alignment: .leading, spacing: 12)) : AnyLayout(HStackLayout())
        return layout {
            Text(day.date.formatted(date: .abbreviated, time: .omitted)).font(.subheadline).frame(maxWidth: .infinity, alignment: .leading)
            PersonalScoreBadge(score: score)
        }
    }
    private func time(_ title: String, _ date: Date?) -> some View {
        LabeledContent(title, value: date?.formatted(date: .omitted, time: .shortened) ?? "—")
    }
    private func stage(_ title: String, metric: PersonalMetric, color: Color, night: PersonalNight) -> some View {
        let hours = night.value(metric)
        return VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label(title, systemImage: "circle.fill").labelStyle(SleepStageLabel(color: color))
                Spacer()
                Text(PersonalChartStyle.duration(hours)).monospacedDigit()
            }.font(.subheadline)
            if let hours, let total = night.hours, total > 0 {
                ProgressView(value: min(total, hours), total: total).tint(color)
                Text("\(Int((hours / total * 100).rounded()))% of sleep").font(.caption).foregroundStyle(.secondary)
            }
        }.padding(.vertical, 6).accessibilityElement(children: .combine)
    }
}
private struct SleepStageLabel: LabelStyle {
    let color: Color
    func makeBody(configuration: Configuration) -> some View {
        HStack { configuration.icon.foregroundStyle(color).imageScale(.small); configuration.title }
    }
}
