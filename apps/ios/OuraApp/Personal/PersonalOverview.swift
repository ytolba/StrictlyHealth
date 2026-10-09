import SwiftUI
import Charts

enum DashboardLens: String, CaseIterable, Identifiable {
    case all = "All", ring = "Oura", watch = "Apple Health"
    var id: String { rawValue }
    func includes(_ source: PersonalSource) -> Bool {
        self == .all || (self == .ring && source == .ring) || (self == .watch && source == .watch)
    }
}

enum DashboardSelection {
    static let defaults: [PersonalMetric] = [.restingHR, .hrv, .steps, .energy, .oxygen]
    static func decode(_ raw: String) -> [PersonalMetric] {
        var seen = Set<PersonalMetric>()
        return raw.split(separator: ",").compactMap { PersonalMetric(rawValue: String($0)) }.filter { seen.insert($0).inserted }
    }
    static var initial: String { defaults.map(\.rawValue).joined(separator: ",") }
}

struct PersonalOverview: View {
    @ObservedObject var model: PersonalDashboardModel
    let ring: RingSync
    var openRing: () -> Void
    var openSettings: () -> Void
    @Environment(\.dynamicTypeSize) private var textSize
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var date = Calendar.current.startOfDay(for: Date())
    @State private var lens = DashboardLens.all
    @State private var editing = false
    @State private var previewSleepReport = false
    @State private var previewLiveCharts = false
    @State private var selectedScore: PersonalScoreKind?
    @AppStorage("dashboard.metrics") private var selection = DashboardSelection.initial
    private var day: PersonalDay? { model.live.byDate[Calendar.current.startOfDay(for: date)] }
    private var scores: PersonalDailyScores? { model.live.scores[Calendar.current.startOfDay(for: date)] }
    private var week: [PersonalDay] {
        let end = Calendar.current.startOfDay(for: date)
        let start = Calendar.current.date(byAdding: .day, value: -6, to: end)!
        return model.live.days.filter { $0.date >= start && $0.date <= end }
    }
    private var metrics: [PersonalMetric] { DashboardSelection.decode(selection) }
    private var visibleMetrics: [PersonalMetric] { metrics.filter { day?.value($0).map { lens.includes($0.source) } ?? (lens == .all) } }
    var body: some View {
        NavigationStack {
            List {
                if model.isDemo { Section { Label("Demo · synthetic data", systemImage: "testtube.2").font(.caption).foregroundStyle(.secondary) } }
                Section {
                    if textSize.isAccessibilitySize {
                        DatePicker("Day", selection: $date, in: ...Date(), displayedComponents: .date).labelsHidden().frame(maxWidth: .infinity)
                        HStack {
                            Button { moveDate(-1) } label: { Image(systemName: "chevron.left").frame(minWidth: 44, minHeight: 44).contentShape(Rectangle()) }.accessibilityLabel("Previous day")
                            Spacer()
                            Button { moveDate(1) } label: { Image(systemName: "chevron.right").frame(minWidth: 44, minHeight: 44).contentShape(Rectangle()) }.accessibilityLabel("Next day").disabled(Calendar.current.isDateInToday(date))
                        }.buttonStyle(.borderless)
                    } else {
                    HStack {
                        Button { moveDate(-1) } label: { Image(systemName: "chevron.left").frame(minWidth: 44, minHeight: 44).contentShape(Rectangle()) }.accessibilityLabel("Previous day")
                        DatePicker("Day", selection: $date, in: ...Date(), displayedComponents: .date).labelsHidden().frame(maxWidth: .infinity)
                        Button { moveDate(1) } label: { Image(systemName: "chevron.right").frame(minWidth: 44, minHeight: 44).contentShape(Rectangle()) }.accessibilityLabel("Next day").disabled(Calendar.current.isDateInToday(date))
                    }.buttonStyle(.borderless)
                    }
                }
                if day == nil || (day?.values.isEmpty == true && day?.night == nil) {
                    Section {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Your day starts here").font(.headline)
                            Text("Sync your ring for direct Oura sleep. Apple Health is optional for Apple Watch measurements.").font(.subheadline)
                        }
                        Button("Connect Apple Health", systemImage: "heart.fill") { Task { await model.connectHealth() } }.disabled(model.refreshing)
                        Button("Set up ring", systemImage: "circle.circle", action: openRing)
                    }
                } else if let day {
                    Section {
                        Button { selectedScore = .sleep } label: {
                            VStack(alignment: .leading, spacing: 14) {
                                let layout = textSize.isAccessibilitySize ? AnyLayout(VStackLayout(alignment: .leading, spacing: 12)) : AnyLayout(HStackLayout(spacing: 10))
                                layout {
                                    HStack {
                                        Image(systemName: "moon.zzz.fill").foregroundStyle(.indigo)
                                        Text("Sleep").font(.title2.weight(.semibold)).fixedSize(horizontal: false, vertical: true)
                                        Spacer(minLength: 0)
                                    }
                                    HStack(spacing: 10) {
                                        PersonalScoreBadge(score: scores?.sleep.score)
                                        Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
                                    }
                                }
                                Text(day.sleepSourceTitle).font(.subheadline)
                                Text(day.night?.hours.map { PersonalChartStyle.duration($0) } ?? "Duration unavailable")
                                    .font(.largeTitle.weight(.semibold)).monospacedDigit().contentTransition(.numericText())
                                    .animation(reduceMotion ? nil : .easeOut(duration: 0.2), value: date)
                                if let night = day.night {
                                    if night.isDirectRing && night.hours == nil { Text("Oura records received; sleep stages are missing or incomplete.").font(.subheadline) }
                                    Text("\(night.asleepStart.map { $0.formatted(date: .omitted, time: .shortened) } ?? "Onset unknown") → \(night.asleepEnd.map { $0.formatted(date: .omitted, time: .shortened) } ?? "Wake unknown")").font(.subheadline).monospacedDigit()
                                    PersonalSleepEssentials(night: night)
                                    if let prepared = model.live.nights[day.date], !prepared.stages.isEmpty {
                                        PersonalStageChart(night: night, stages: prepared.stages, compact: true, interactive: false)
                                    } else { Text("Sleep stages unavailable").font(.caption).foregroundStyle(.secondary) }
                                    Text(PersonalDisplay.sleepStory(night, goal: model.goals.sleepHours)).font(.subheadline).foregroundStyle(.secondary)
                                } else { Text(day.sleepUnavailableMessage).font(.subheadline) }
                            }.padding(.vertical, 8).contentShape(Rectangle())
                        }.buttonStyle(.plain).accessibilityHint("Opens sleep timing, stages and overnight measurements")
                    }
                    if day.night == nil, model.preferences.resolvedSleepInput == .directRing {
                        Button("Sync Oura ring", systemImage: "arrow.triangle.2.circlepath", action: openRing)
                    }
                    Section {
                        Button { selectedScore = .activity } label: {
                            PersonalTopicRow(kind: .activity, score: scores?.activity.score,
                                detail: PersonalDisplay.value(day.value(.steps)?.value, metric: .steps) + " steps" + (scores?.activity.estimated == true ? " · Estimated" : ""))
                        }.buttonStyle(.plain)
                        Button { selectedScore = .recovery } label: {
                            PersonalTopicRow(kind: .recovery, score: scores?.recovery.score,
                                detail: scores?.recovery.score.map { ScoreBand.forScore(Double($0)).rawValue } ?? "Building your baseline")
                        }.buttonStyle(.plain)
                    }
                    Section {
                        DisclosureGroup("Measurements") {
                            Picker("Source", selection: $lens) {
                                ForEach(DashboardLens.allCases) { Text($0.rawValue).tag($0) }
                            }.pickerStyle(.segmented)
                            if visibleMetrics.isEmpty { Text("No measurements from this source.").foregroundStyle(.secondary) }
                            ForEach(visibleMetrics) { metric in measurement(metric, day: day) }
                            Button("Customize measurements") { editing = true }
                        }
                    }
                }
                Section {
                    if model.status.hasPrefix("Refresh failed") || model.status.hasPrefix("Could not") { Label(model.status, systemImage: "exclamationmark.circle").font(.footnote) }
                    DisclosureGroup("Sync details") {
                        Text(model.status).font(.footnote)
                        if let refreshed = model.lastRefresh { Text("Updated \(refreshed.formatted(date: .abbreviated, time: .shortened))").font(.caption).foregroundStyle(.secondary) }
                        Button("Source preferences", action: openSettings)
                    }
                }
            }
            .navigationTitle("Today")
            .listSectionSpacing(.compact)
            .refreshable { await model.refresh() }
            .toolbar {
                ToolbarItemGroup(placement: .topBarTrailing) {
                    PersonalRingHeader(ring: ring, openRing: openRing)
                    Button("Customize", systemImage: "slider.horizontal.3") { editing = true }
                }
            }
            .sheet(isPresented: $editing) { measurementEditor }
            .navigationDestination(isPresented: $previewSleepReport) {
                if let day { PersonalSleepReport(day: day, summary: scores, charts: model.live.nights[day.date], days: week, goals: model.goals) }
            }
            .navigationDestination(item: $selectedScore) { kind in
                if let day, let scores {
                    if kind == .sleep { PersonalSleepReport(day: day, summary: scores, charts: model.live.nights[day.date], days: week, goals: model.goals) }
                    else { PersonalFocusReport(kind: kind, day: day, scores: scores, days: week, goals: model.goals, isDemo: model.isDemo) }
                }
            }
            #if DEBUG
            .navigationDestination(isPresented: $previewLiveCharts) {
                if let day, let night = day.night, let prepared = model.live.nights[day.date] { PersonalLiveChartPreview(days: week, night: night, charts: prepared) }
            }
            #endif
            .task(id: model.live.days.count) {
                #if DEBUG
                if model.isDemo && ProcessInfo.processInfo.arguments.contains("--preview-sleep-report"), day != nil { previewSleepReport = true }
                if model.isDemo && ProcessInfo.processInfo.arguments.contains("--preview-live-charts"), day != nil { previewLiveCharts = true }
                if model.isDemo && ProcessInfo.processInfo.arguments.contains("--preview-activity"), day != nil { selectedScore = .activity }
                if model.isDemo && ProcessInfo.processInfo.arguments.contains("--preview-recovery"), day != nil { selectedScore = .recovery }
                #endif
            }
        }
    }
    private func moveDate(_ amount: Int) { date = Calendar.current.date(byAdding: .day, value: amount, to: date) ?? date }
    private func provenance(identity: String) -> String {
        identity.hasPrefix("oura-account-export") ? "Oura account export · imported" : (identity.hasPrefix("direct-ring") ? "Direct ring · Bluetooth" : "Apple Health · chosen source")
    }
    private func measurement(_ metric: PersonalMetric, day: PersonalDay) -> some View {
        let value = day.value(metric)
        return VStack(alignment: .leading, spacing: 5) {
            let layout = textSize.isAccessibilitySize ? AnyLayout(VStackLayout(alignment: .leading, spacing: 4)) : AnyLayout(HStackLayout(alignment: .firstTextBaseline))
            layout {
                Text(metric.title)
                Spacer(minLength: 4)
                Text(PersonalDisplay.value(value?.value, metric: metric)).font(.headline).monospacedDigit()
            }
            Text(value.map { [provenance(identity: $0.identity), $0.method].compactMap { $0 }.joined(separator: " · ") } ?? "No available data").font(.caption).foregroundStyle(.secondary)
        }.padding(.vertical, 3)
    }
    private var measurementEditor: some View {
        NavigationStack {
            List {
                Section {
                    Text("Choose which measurements appear on Today. Source priorities remain separate in Settings.").font(.footnote).foregroundStyle(.secondary)
                }
                Section("Shown in this order") {
                    ForEach(metrics) { Text($0.title) }
                        .onMove { from, to in var rows = metrics; rows.move(fromOffsets: from, toOffset: to); selection = rows.map(\.rawValue).joined(separator: ",") }
                }
                Section("Measurements") {
                    ForEach(PersonalMetric.allCases.filter { $0 != .workouts }) { metric in
                        Toggle(metric.title, isOn: Binding(get: { metrics.contains(metric) }, set: { enabled in
                            var rows = metrics.filter { $0 != metric }; if enabled { rows.append(metric) }; selection = rows.map(\.rawValue).joined(separator: ",")
                        }))
                    }
                }
            }.environment(\.editMode, .constant(.active))
                .navigationTitle("Your overview").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { editing = false } } }
        }.tint(.teal)
    }
}

private struct PersonalRingHeader: View {
    @ObservedObject var ring: RingSync
    var openRing: () -> Void
    var body: some View {
        Button(action: openRing) {
            VStack(spacing: 2) {
                HStack(spacing: 4) {
                    if ring.checkingBattery { ProgressView().controlSize(.mini) }
                    else { Image(systemName: ring.connectionState == .connected ? "circle.inset.filled" : "circle.dotted").foregroundStyle(ring.connectionState == .connected ? Color.green : Color.secondary) }
                    Image(systemName: ring.batterySymbol)
                    Text(ring.batteryPercent.map { "\($0)%" } ?? "—").monospacedDigit()
                }
                Text(ring.connectionState.rawValue).font(.caption2)
            }.font(.caption).frame(minWidth: 70, minHeight: 44)
        }.accessibilityLabel("Oura ring, \(ring.connectionState.rawValue), battery \(ring.batteryPercent.map { "\($0) percent, last reading" } ?? "unavailable"). Open ring details.")
    }
}

private struct DashboardScore: View {
    var title: String
    var score: Double?
    var origin: String
    var body: some View {
        VStack(alignment: .center, spacing: 6) {
            ZStack {
                Circle().stroke(.quaternary, lineWidth: 5)
                if let score { Circle().trim(from: 0, to: min(1, max(0, score / 100))).stroke(ScoreBand.forScore(score).color, style: StrokeStyle(lineWidth: 5, lineCap: .round)).rotationEffect(.degrees(-90)) }
                Text(score.map { String(Int($0.rounded())) } ?? "—").font(.title2.weight(.semibold)).monospacedDigit()
            }.frame(width: 72, height: 72).accessibilityHidden(true)
            Text(title).font(.subheadline.weight(.semibold))
            if let score { Text(ScoreBand.forScore(score).rawValue).font(.caption.weight(.medium)) }
            Text(score == nil ? "Unavailable" : origin).font(.caption).foregroundStyle(.secondary)
        }.multilineTextAlignment(.center).frame(maxWidth: .infinity, alignment: .center)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("\(title), \(score.map { String(Int($0.rounded())) + " out of 100, " + ScoreBand.forScore($0).rawValue + ", " + origin } ?? "unavailable")")
    }
}

enum ScoreBand: String {
    case high = "High", moderate = "Moderate", low = "Low"
    static func forScore(_ score: Double) -> Self { score >= 85 ? .high : (score >= 70 ? .moderate : .low) }
    // Explicit light/dark data colors; labels carry the meaning without color.
    var color: Color {
        Color(UIColor { traits in
            let dark = traits.userInterfaceStyle == .dark
            switch self {
            case .high: return dark ? UIColor(red: 0.34, green: 0.84, blue: 0.48, alpha: 1) : UIColor(red: 0.09, green: 0.48, blue: 0.24, alpha: 1)
            case .moderate: return dark ? UIColor(red: 1, green: 0.72, blue: 0.25, alpha: 1) : UIColor(red: 0.65, green: 0.35, blue: 0.03, alpha: 1)
            case .low: return dark ? UIColor(red: 1, green: 0.45, blue: 0.43, alpha: 1) : UIColor(red: 0.75, green: 0.17, blue: 0.15, alpha: 1)
            }
        })
    }
}

struct PersonalLaunchView: View {
    @ScaledMetric(relativeTo: .title2) private var logoSize = 128.0
    var body: some View {
        VStack(spacing: 16) {
            Image("StrictlyHealthMark").resizable().scaledToFit()
                .frame(width: logoSize, height: logoSize).accessibilityHidden(true)
            Text("StrictlyHealth").font(.title2).multilineTextAlignment(.center)
        }.padding(.horizontal, 24).frame(maxWidth: .infinity, maxHeight: .infinity).background(Color(uiColor: .systemBackground)).accessibilityElement(children: .combine)
    }
}
