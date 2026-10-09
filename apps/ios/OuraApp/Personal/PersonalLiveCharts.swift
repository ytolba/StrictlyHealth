import SwiftUI
import Charts

enum PersonalChartStyle {
    static let stages: KeyValuePairs<String, Color> = ["Awake": .orange, "REM": .cyan, "Core": .blue, "Deep": .indigo, "Asleep": .gray]
    static func duration(_ hours: Double?) -> String {
        guard let hours, hours.isFinite, hours >= 0 else { return "—" }
        let minutes = Int((hours * 60).rounded())
        return "\(minutes / 60) h \(minutes % 60) min"
    }
}

struct PersonalStageChart: View {
    let night: PersonalNight
    let stages: [PersonalStage]
    var compact = false
    var interactive = true
    @Environment(\.dynamicTypeSize) private var textSize
    @ScaledMetric(relativeTo: .caption2) private var fullHeight = 165.0
    @ScaledMetric(relativeTo: .caption2) private var compactHeight = 105.0
    @State private var selected: Date?
    private var picked: PersonalStage? {
        guard let selected else { return nil }
        return stages.first { $0.start <= selected && selected < $0.end }
    }
    static func level(_ label: String) -> Double? {
        ["Deep": 0.0, "Core": 1, "REM": 2, "Awake": 3, "Asleep": 4][label]
    }
    private var labels: [String] { stages.contains { $0.label == "Asleep" } ? ["Deep", "Light", "REM", "Awake", "Asleep"] : ["Deep", "Light", "REM", "Awake"] }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if interactive, let selected {
                Text(picked.map { "\($0.label == "Core" ? "Light" : $0.label) · \($0.start.formatted(date: .omitted, time: .shortened))–\($0.end.formatted(date: .omitted, time: .shortened))" } ?? "\(selected.formatted(date: .omitted, time: .shortened)) · No recorded stage").font(.caption).monospacedDigit()
            }
            Chart {
                ForEach(Array(stages.enumerated()), id: \.offset) { _, stage in
                    if let level = Self.level(stage.label) {
                        RectangleMark(xStart: .value("Start", stage.start), xEnd: .value("End", stage.end), yStart: .value("Stage", level + 0.05), yEnd: .value("Stage", level + 0.75))
                            .foregroundStyle(by: .value("Stage", stage.label)).cornerRadius(2)
                    }
                }
                if let selected, interactive { RuleMark(x: .value("Selected time", selected)).foregroundStyle(.secondary.opacity(0.3)) }
            }.chartForegroundStyleScale(PersonalChartStyle.stages)
                .chartLegend(.hidden).chartXScale(domain: night.start...night.end)
                .chartYScale(domain: 0...Double(labels.count))
                .chartYAxis { AxisMarks(position: .leading, values: (0..<labels.count).map { Double($0) + 0.4 }) { axis in
                    AxisGridLine()
                    AxisValueLabel { if let value = axis.as(Double.self) { Text(labels[min(labels.count - 1, Int(value))]).font(.caption2) } }
                } }
                .chartXAxis { AxisMarks(values: .stride(by: .hour, count: textSize.isAccessibilitySize ? 4 : 2)) { _ in AxisGridLine(); AxisValueLabel(format: .dateTime.hour()) } }
                .chartXSelection(value: Binding(get: { interactive ? selected : nil }, set: { if interactive { selected = $0 } }))
                .allowsHitTesting(interactive)
                .frame(height: compact ? compactHeight : fullHeight)
                .accessibilityLabel("Sleep stage timeline. Exact stage durations follow below.")
            if compact {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 18) { stageTotals }
                    VStack(alignment: .leading, spacing: 10) { stageTotals }
                }
            }
        }
    }
    @ViewBuilder private var stageTotals: some View {
        ForEach([(PersonalMetric.deepSleep, "Deep", Color.indigo), (.remSleep, "REM", .cyan), (.lightSleep, "Light", .blue)], id: \.0) { metric, title, color in
            VStack(alignment: .leading, spacing: 4) {
                Label(title, systemImage: "circle.fill").font(.caption).foregroundStyle(.primary)
                    .labelStyle(StageLegendStyle(color: color))
                Text(PersonalChartStyle.duration(night.value(metric))).font(.caption.weight(.semibold)).monospacedDigit()
            }.accessibilityElement(children: .combine)
        }
    }
}
private struct StageLegendStyle: LabelStyle {
    let color: Color
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 5) { configuration.icon.foregroundStyle(color).imageScale(.small); configuration.title }
    }
}

struct PersonalHeartChart: View {
    let points: [PersonalPlotPoint]
    let start: Date
    let end: Date
    var unit = "bpm"
    var color = Color.teal
    @State private var selected: Date?
    @ScaledMetric(relativeTo: .caption) private var chartHeight = 170.0
    private var nearest: PersonalPlotPoint? {
        guard let selected else { return nil }
        return PersonalNightCharts.inspectedPoint(selected, points: points)
    }
    var body: some View {
        let inspected = nearest
        VStack(alignment: .leading, spacing: 10) {
            if let nearest = inspected { Text("\(nearest.time.formatted(date: .omitted, time: .shortened)) · \(Int(nearest.value.rounded())) \(unit)").font(.subheadline.weight(.semibold)).monospacedDigit() }
            else if selected != nil { Text("No measurement near this time.").font(.subheadline).foregroundStyle(.secondary) }
            Chart(Array(points.enumerated()), id: \.offset) { _, point in
                LineMark(x: .value("Time", point.time), y: .value(unit, point.value), series: .value("Recorded interval", point.segment))
                    .foregroundStyle(color).lineStyle(StrokeStyle(lineWidth: 2))
                PointMark(x: .value("Time", point.time), y: .value(unit, point.value)).foregroundStyle(color).symbolSize(8)
                if let nearest = inspected, point.time == nearest.time {
                    PointMark(x: .value("Time", point.time), y: .value(unit, point.value)).foregroundStyle(color)
                    RuleMark(x: .value("Selected time", point.time)).foregroundStyle(.secondary.opacity(0.4))
                }
            }.chartXScale(domain: start...end)
                .chartYScale(domain: .automatic(includesZero: false))
                .chartXSelection(value: $selected).frame(height: chartHeight)
                .accessibilityLabel(unit == "bpm" ? "Overnight heart rate in beats per minute" : "Overnight HRV in milliseconds")
            DisclosureGroup("Chart details") {
                Text("Drag to inspect. Gaps over 15 minutes are not joined. Display points may be reduced; originals remain stored.").font(.caption).foregroundStyle(.secondary)
            }.font(.caption)
        }
    }
}

struct PersonalWeekChart: View {
    let days: [PersonalDay]
    let metric: PersonalMetric
    let goal: Double?
    let endingOn: Date
    @State private var selected: Date?
    @ScaledMetric(relativeTo: .caption) private var chartHeight = 145.0
    static func range(endingOn: Date, calendar: Calendar = .current) -> ClosedRange<Date> {
        let endDay = calendar.startOfDay(for: endingOn)
        let start = calendar.date(byAdding: .day, value: -6, to: endDay)!
        return start...calendar.date(byAdding: .day, value: 1, to: endDay)!
    }
    private var window: ClosedRange<Date> { Self.range(endingOn: endingOn) }
    private var rows: [PersonalDay] { days.filter { $0.date >= window.lowerBound && $0.date < window.upperBound && $0.value(metric) != nil } }
    private func provenance(_ value: PersonalValue) -> String {
        let estimate = [.steps, .energy].contains(metric) && value.identity.hasPrefix("direct-ring")
        return [value.source.rawValue, value.method ?? (metric == .hrv ? "Method unknown" : nil), estimate ? "Estimated" : nil].compactMap { $0 }.joined(separator: " · ")
    }
    private var picked: PersonalDay? {
        guard let selected else { return nil }
        return rows.first { Calendar.current.isDate($0.date, inSameDayAs: selected) }
    }
    private var series: [Date: String] {
        var previous: [String: Date] = [:], segments: [String: Int] = [:], result: [Date: String] = [:]
        for day in rows.sorted(by: { $0.date < $1.date }) {
            guard let value = day.value(metric) else { continue }
            let identity = value.identity + "|" + (value.method ?? "")
            if let last = previous[identity], day.date.timeIntervalSince(last) > 36 * 3600 { segments[identity, default: 0] += 1 }
            result[day.date] = identity + "|" + String(segments[identity, default: 0])
            previous[identity] = day.date
        }
        return result
    }
    var body: some View {
        let segments = series
        VStack(alignment: .leading, spacing: 10) {
            if let picked, let value = picked.value(metric) {
                Text("\(picked.date.formatted(.dateTime.weekday(.wide))) · \(PersonalDisplay.value(value.value, metric: metric))").font(.subheadline.weight(.semibold)).monospacedDigit()
                Text(provenance(value)).font(.caption).foregroundStyle(.secondary)
            }
            if rows.isEmpty { Text("No live measurements for this week yet.").foregroundStyle(.secondary) }
            else {
                Chart {
                    ForEach(rows) { day in
                    if let value = day.value(metric) {
                        if metric == .hrv {
                            LineMark(x: .value("Day", day.date, unit: .day), y: .value(metric.title, PersonalDisplay.number(value.value, metric: metric)), series: .value("Method / device", segments[day.date] ?? value.identity))
                                .foregroundStyle(.teal).lineStyle(StrokeStyle(lineWidth: 2))
                            PointMark(x: .value("Day", day.date, unit: .day), y: .value(metric.title, PersonalDisplay.number(value.value, metric: metric))).foregroundStyle(.teal)
                        } else {
                            BarMark(x: .value("Day", day.date, unit: .day), y: .value(metric.title, PersonalDisplay.number(value.value, metric: metric)))
                                .foregroundStyle(metric == .sleep ? Color.indigo : Color.teal).cornerRadius(4)
                        }
                    }
                    }
                    if let goal { RuleMark(y: .value("Your goal", PersonalDisplay.number(goal, metric: metric))).foregroundStyle(.secondary).lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 4])) }
                }.chartXScale(domain: window)
                    .chartXAxis { AxisMarks(values: (0..<7).compactMap { Calendar.current.date(byAdding: .day, value: $0, to: window.lowerBound) }) { _ in AxisValueLabel(format: .dateTime.weekday(.narrow)) } }
                    .chartXSelection(value: $selected).frame(height: chartHeight)
                if let goal { Text("Goal \(PersonalDisplay.value(goal, metric: metric))").font(.caption).foregroundStyle(.secondary) }
                DisclosureGroup("Daily values & sources") {
                    Text(metric == .hrv ? "Different HRV methods and devices are not joined. Missing days stay missing." : "Missing days are gaps, not zero.").foregroundStyle(.secondary)
                    ForEach(rows) { day in
                        if let value = day.value(metric) {
                            VStack(alignment: .leading, spacing: 4) {
                                Text("\(day.date.formatted(.dateTime.weekday(.wide))) · \(PersonalDisplay.value(value.value, metric: metric))")
                                Text(provenance(value)).foregroundStyle(.secondary)
                            }.font(.caption).accessibilityElement(children: .combine)
                        }
                    }
                }.font(.caption)
            }
        }
    }
}

#if DEBUG
// Native screenshot harness for the very same lower-screen chart components.
struct PersonalLiveChartPreview: View {
    let days: [PersonalDay]
    let night: PersonalNight
    let charts: PersonalNightCharts
    var body: some View {
        List {
            Section { Label("Demo · synthetic chart preview", systemImage: "testtube.2").font(.caption) }
            if ProcessInfo.processInfo.arguments.contains("--preview-stage-chart") {
                Section("Sleep timeline") { PersonalStageChart(night: night, stages: charts.stages, compact: true, interactive: false) }
            } else {
            Section("Overnight heart rate") { PersonalHeartChart(points: charts.heartRate, start: night.start, end: night.end) }
            Section("Overnight HRV · RMSSD") { PersonalHeartChart(points: charts.hrv, start: night.start, end: night.end, unit: "ms", color: .indigo) }
            Section("Seven nights") { PersonalWeekChart(days: days, metric: .sleep, goal: 8, endingOn: night.end) }
            }
        }.navigationTitle("Live charts").navigationBarTitleDisplayMode(.inline)
    }
}
#endif

enum PersonalScoreKind: String, Hashable { case sleep = "Sleep", activity = "Activity", recovery = "Recovery" }
struct PersonalLiveScoreDetail: View {
    let kind: PersonalScoreKind
    let day: PersonalDay
    let scores: PersonalDailyScores
    private var result: PersonalLiveScore? { kind == .sleep ? scores.sleep : (kind == .activity ? scores.activity : nil) }
    var body: some View {
        List {
            Section("Our \(kind.rawValue.lowercased()) score") {
                let value = result?.score ?? (kind == .recovery ? scores.recovery.score : nil)
                LabeledContent(day.date.formatted(date: .abbreviated, time: .omitted), value: value.map { "\($0) / 100" } ?? "Unavailable")
                if result?.estimated == true { Label("Uses estimated ring activity", systemImage: "exclamationmark.circle").foregroundStyle(.secondary) }
                Text(result?.explanation ?? scores.recovery.explanation).font(.footnote)
                Text("Independent app formula—not an official Oura score or medical assessment.").font(.footnote).foregroundStyle(.secondary)
            }
            if let result {
                Section("Breakdown") {
                    ForEach(result.components) { component in
                        VStack(alignment: .leading, spacing: 8) {
                            LabeledContent(component.title, value: component.score.map { "\(Int($0.rounded())) / 100" } ?? "Unavailable")
                            if let value = component.score { ProgressView(value: value, total: 100).tint(ScoreBand.forScore(value).color) }
                            Text("\(Int(component.weight * 100))% weight · \(component.detail)").font(.caption).foregroundStyle(.secondary)
                        }.padding(.vertical, 4)
                    }
                    Text("Available component coverage: \(Int(result.coverage * 100))%.").font(.caption).foregroundStyle(.secondary)
                }
            }
            if kind == .activity {
                Section("Inputs") {
                    ForEach([PersonalMetric.steps, .energy]) { metric in
                        if let value = day.value(metric) {
                            LabeledContent(metric.title, value: "\(value.value.formatted(.number.precision(.fractionLength(0)))) \(metric.unit)")
                            Text([value.source.rawValue, value.method].compactMap { $0 }.joined(separator: " · ")).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    Text("Change your goals in Settings. Activity progress increases throughout the day.").font(.footnote).foregroundStyle(.secondary)
                }
            }
        }.navigationTitle(kind.rawValue + " breakdown").navigationBarTitleDisplayMode(.inline)
    }
}
