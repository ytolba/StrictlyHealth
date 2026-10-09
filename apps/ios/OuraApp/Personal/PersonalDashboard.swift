import SwiftUI
import SwiftData
import Charts
import Combine
import UniformTypeIdentifiers

@MainActor final class PersonalDashboardModel: ObservableObject {
    @Published var days: [PersonalDay] = []
    @Published private(set) var live = PersonalLiveSnapshot()
    @Published var goals = PersonalGoals.load()
    @Published var preferences = PersonalPreferences.load()
    @Published var status = "Connect Apple Health and sync your ring to get started."
    @Published var refreshing = false
    @Published var lastRefresh: Date?
    @Published var archiveCount = 0
    @Published var importStatus = ""
    let health = PersonalHealthReader()
    private var cache: PersonalCacheWorker?
    private var authorized = UserDefaults.standard.bool(forKey: "personal.health.connected")
    private var refreshPending = false
    private var scheduled: Task<Void, Never>?
    var isDemo: Bool {
        #if DEBUG
        ProcessInfo.processInfo.arguments.contains("--demo-dashboard")
        #else
        false
        #endif
    }
    func start(context: ModelContext) async {
        guard cache == nil else { return }
        let container = context.container
        cache = await Task.detached(priority: .utility) { PersonalCacheWorker(modelContainer: container) }.value
        if isDemo {
            days = DashboardDemo.days()
            await prepareLive()
            status = "Demo · synthetic data. No HealthKit or ring connection; demo records are never saved."
            return
        }
        do {
            let saved = try await cache!.load()
            days = saved.days
            archiveCount = saved.archiveCount
            lastRefresh = saved.refreshedAt
            await prepareLive()
            if !days.isEmpty { status = "Showing cached data. Refresh to read current permissions and samples." }
        } catch { status = "Could not read the local cache: \(error.localizedDescription)" }
        if authorized { health.observe() }
        health.onChange = { [weak self] in
            Task { @MainActor in self?.scheduleRefresh(healthUpdate: true) }
        }
    }
    private func scheduleRefresh(healthUpdate: Bool = false) {
        scheduled?.cancel()
        let delay = healthUpdate ? max(1, 30 - Date().timeIntervalSince(lastRefresh ?? .distantPast)) : 1
        scheduled = Task { @MainActor [weak self] in
            do { try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000)) } catch { return }
            await self?.refresh()
        }
    }
    func connectHealth() async {
        guard !isDemo else { return }
        do {
            try await health.authorize()
            authorized = true
            UserDefaults.standard.set(true, forKey: "personal.health.connected")
            health.observe()
            await refresh()
        } catch { status = "Apple Health: \(error.localizedDescription)" }
    }
    func refresh() async {
        guard !isDemo else { return }
        guard !refreshing else { refreshPending = true; return }
        refreshing = true
        defer {
            refreshing = false
            if refreshPending { refreshPending = false; scheduleRefresh() }
        }
        let now = Date()
        let start = Calendar.current.date(byAdding: .day, value: -120, to: Calendar.current.startOfDay(for: now))!
        do {
            let reader = health, hasHealth = authorized, preferences = preferences, oldDays = days
            let result = try await Task.detached(priority: .utility) {
                let ring = Core.base()
                let snapshot = hasHealth ? try await reader.fetch(start: start, end: now) : PersonalHealthSnapshot()
                let archive = try PersonalArchive.loadValidated()
                let previous = oldDays.filter { $0.date < start }.map { day -> PersonalDay in
                    var cached = day
                    // Archive rows are merged again from the durable original store below.
                    cached.archiveRecords = nil
                    cached.values = cached.values.filter { !$0.value.identity.hasPrefix("oura-account-export") }
                    if cached.night?.identity.hasPrefix("oura-account-export") == true { cached.night = nil }
                    return cached
                }
                let built = PersonalArchive.merge(previous + PersonalAssembler.build(ring: ring.error == nil ? ring : nil, health: snapshot, preferences: preferences, now: now), records: archive)
                return (days: built, ringError: ring.error, archiveEmpty: archive.isEmpty)
            }.value
            if result.ringError != nil && !authorized && result.archiveEmpty {
                status = "Sync your ring or connect Apple Health first. \(result.ringError ?? "")"
                return
            }
            let changed = try await cache?.persist(result.days) ?? true
            if changed { days = result.days }
            await prepareLive()
            lastRefresh = now
            status = authorized ? "Updated. Missing values can mean no samples or read access unavailable; HealthKit does not disclose read denial." : (result.ringError == nil ? "Ring data updated. Connect Apple Health for Apple Watch metrics." : "Imported history updated. Live ring data is unavailable; connect Apple Health for Apple Watch metrics.")
        } catch { status = "Refresh failed; cached data retained. \(error.localizedDescription)" }
    }
    func savePreferences() {
        guard !isDemo else { return }
        preferences.save()
        scheduleRefresh()
    }
    func saveGoals() {
        guard !isDemo else { return }
        goals.save()
        Task { await prepareLive() }
    }
    private var presentationRevision = 0
    private func prepareLive() async {
        presentationRevision += 1
        let revision = presentationRevision
        let stored = days, preferences = preferences, goals = goals
        let snapshot = await Task.detached(priority: .utility) { PersonalLiveSnapshot.build(stored, preferences: preferences, goals: goals) }.value
        guard revision == presentationRevision else { return }
        live = snapshot
    }
    func importArchive(_ urls: [URL]) async {
        guard !isDemo else { return }
        guard !refreshing else { importStatus = "Wait for the current refresh, then import again."; return }
        refreshing = true
        do {
            let result = try await Task.detached(priority: .utility) {
                let result = try PersonalArchive.read(urls)
                var records = Dictionary(try PersonalArchive.loadValidated().map { ($0.id, $0) }, uniquingKeysWith: { _, new in new })
                for record in result.records { records[record.id] = record }
                let saved = records.values.sorted { $0.id < $1.id }
                try PersonalArchive.save(saved)
                return (records: result.records.count, skipped: result.skipped, saved: saved.count)
            }.value
            archiveCount = result.saved
            importStatus = "Imported \(result.records) records. \(result.skipped) undated rows skipped. Historical data stays on this iPhone."
            refreshing = false
            await refresh()
        } catch {
            refreshing = false
            importStatus = "Import failed; previous history retained. \(error.localizedDescription)"
        }
    }
}

struct PersonalAppRoot: View {
    @State private var container: ModelContainer?
    @State private var error: String?
    var body: some View {
        Group {
            if let container { PersonalDashboard().modelContainer(container) }
            else if let error { ContentUnavailableView("Local storage unavailable", systemImage: "externaldrive.badge.exclamationmark", description: Text(error)) }
            else { PersonalLaunchView() }
        }.task {
            guard container == nil, error == nil else { return }
            do {
                container = try await Task.detached(priority: .userInitiated) {
                    try ModelContainer(for: PersonalCachedDay.self,
                        configurations: ModelConfiguration(cloudKitDatabase: .none))
                }.value
            } catch { self.error = error.localizedDescription }
        }
    }
}
struct PersonalDashboard: View {
    @Environment(\.modelContext) private var context
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var model = PersonalDashboardModel()
    @StateObject private var ring = RingSync()
    @State private var starting = true
    @State private var foregroundRefreshing = false
    @State private var lastForegroundRefresh: Date?
    @State private var tab = 0
    var body: some View {
        TabView(selection: $tab) {
            PersonalOverview(model: model, ring: ring, openRing: { tab = 2 }, openSettings: { tab = 3 }).tabItem { Label("Today", systemImage: "heart.text.square") }.tag(0)
            PersonalTrends(model: model).tabItem { Label("Trends", systemImage: "chart.xyaxis.line") }.tag(1)
            PersonalHistory(model: model).tabItem { Label("History", systemImage: "calendar") }.tag(4)
            PersonalRing(model: model, ring: ring).tabItem { Label("Ring", systemImage: "circle.circle") }.tag(2)
            PersonalSettings(model: model).tabItem { Label("Settings", systemImage: "gearshape") }.tag(3)
        }
        .tint(.teal)
        .overlay { if starting { PersonalLaunchView().transition(.opacity) } }
        .task {
            #if DEBUG
            if ProcessInfo.processInfo.arguments.contains("--preview-launch") { return }
            #endif
            await model.start(context: context)
            starting = false
            await refreshForeground()
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active && !starting { Task { await refreshForeground() } }
        }
    }
    private func refreshForeground() async {
        guard WorkCoordinator.shared.available else { return }
        guard !foregroundRefreshing else { return }
        if let lastForegroundRefresh, Date().timeIntervalSince(lastForegroundRefresh) < 15 { return }
        foregroundRefreshing = true; lastForegroundRefresh = Date()
        defer { foregroundRefreshing = false }
        async let data: Void = model.refresh()
        if !model.isDemo { await ring.refreshBattery(automatic: true) }
        await data
    }
}
struct PersonalTrends: View {
    @ObservedObject var model: PersonalDashboardModel
    @State private var window = 30
    @State private var metric = PersonalMetric.hrv
    var body: some View {
        NavigationStack {
            List {
                Picker("Metric", selection: $metric) {
                    ForEach(PersonalMetric.allCases) { Text($0.title).tag($0) }
                }
                Picker("Window", selection: $window) { ForEach([7, 30, 90, 365, 0], id: \.self) { Text($0 == 0 ? "All" : "\($0)d").tag($0) } }.pickerStyle(.segmented)
                let cutoff = Calendar.current.date(byAdding: .day, value: -(window - 1), to: Calendar.current.startOfDay(for: Date()))!
                let days = model.live.days.filter { (window == 0 || $0.date >= cutoff) && $0.value(metric) != nil }
                if days.isEmpty { ContentUnavailableView("No data for this period", systemImage: "chart.xyaxis.line") }
                else {
                    Chart(days) { day in
                        if let value = day.value(metric) {
                            // Separate series prevents connecting RMSSD to SDNN or unlike sources.
                            LineMark(x: .value("Day", day.date), y: .value(metric.title, PersonalDisplay.number(value.value, metric: metric)))
                                .foregroundStyle(by: .value("Source / method", value.identity + " · " + (value.method ?? metric.title)))
                            PointMark(x: .value("Day", day.date), y: .value(metric.title, PersonalDisplay.number(value.value, metric: metric)))
                                .foregroundStyle(by: .value("Source / method", value.identity + " · " + (value.method ?? metric.title)))
                        }
                    }
                    .chartLegend(.hidden)
                    .chartYAxisLabel(PersonalDisplay.unit(metric))
                    .frame(height: 240)
                    ForEach(days.reversed()) { day in
                        if let value = day.value(metric) {
                            VStack(alignment: .leading) {
                                LabeledContent(day.date.formatted(date: .abbreviated, time: .omitted), value: PersonalDisplay.value(value.value, metric: metric))
                                Text([value.source.rawValue, value.method].compactMap { $0 }.joined(separator: " · ")).font(.caption).foregroundStyle(.secondary)
                                if metric.sleepMetric, let night = day.night { NavigationLink("Sleep detail") { PersonalSleepDetail(night: night) } }
                            }
                        }
                    }
                }
            }
            .navigationTitle("Trends")
        }
    }
}
struct PersonalSleepDetail: View {
    let night: PersonalNight
    var body: some View {
        List {
            Section("\(night.source.rawValue) · one source for this night") {
                Text(night.provenance ?? "Apple Health sleep records").font(.caption).foregroundStyle(.secondary)
                LabeledContent("Sleep", value: night.hours.map { String(format: "%.1f h", $0) } ?? "Unavailable")
                LabeledContent("Window", value: "\(night.start.formatted(date: .omitted, time: .shortened))–\(night.end.formatted(date: .omitted, time: .shortened))")
                LabeledContent("Fell asleep", value: night.asleepStart?.formatted(date: .abbreviated, time: .shortened) ?? "Unavailable without stages")
                LabeledContent("Last sleep ended", value: night.asleepEnd?.formatted(date: .abbreviated, time: .shortened) ?? "Unavailable without stages")
                ForEach([PersonalMetric.timeInBed, .deepSleep, .remSleep, .lightSleep, .awake, .wakeAfterSleep, .efficiency, .latency, .awakenings, .restlessPeriods]) { metric in
                    LabeledContent(metric.title, value: PersonalDisplay.value(night.value(metric), metric: metric))
                }
                Text("Stage coverage \(Int(night.coverage * 100))%. Awakenings are contiguous recorded awake episodes between first and last sleep—not clinically measured arousals.").font(.caption).foregroundStyle(.secondary)
                if night.stages.isEmpty { Text("Sleep stages unavailable; time in bed is not counted as sleep.") }
                else {
                    Chart(Array(night.chartStages.enumerated()), id: \.offset) { _, stage in
                        BarMark(xStart: .value("Start", stage.start), xEnd: .value("End", stage.end), y: .value("Stage", stage.label))
                            .foregroundStyle(by: .value("Stage", stage.label))
                    }.chartXScale(domain: night.start...night.end).frame(height: 180)
                }
            }
            Section("When you woke during the night") {
                if night.awakeningSpans.isEmpty { Text(night.coverage >= 0.95 ? "No recorded awakenings." : "Not enough stage data to determine awakenings.") }
                ForEach(Array(night.awakeningSpans.enumerated()), id: \.offset) { _, span in
                    LabeledContent("\(span.start.formatted(date: .omitted, time: .shortened))–\(span.end.formatted(date: .omitted, time: .shortened))", value: String(format: "%.1f min", span.end.timeIntervalSince(span.start) / 60))
                }
            }
            Section("Overnight heart rate · \(night.source.rawValue)") {
                if night.heartRate.isEmpty { Text("No available overnight heart-rate samples.") }
                else {
                    Chart(Array(night.heartRate.enumerated()), id: \.offset) { _, point in
                        LineMark(x: .value("Time", point.time), y: .value("bpm", point.value))
                    }.chartXScale(domain: night.start...night.end).frame(height: 180)
                }
            }
        }.navigationTitle("Sleep detail")
    }
}
struct PersonalSettings: View {
    @ObservedObject var model: PersonalDashboardModel
    @State private var importing = false
    var body: some View {
        NavigationStack {
            Form {
                Section("Apple Health") {
                    Button("Connect or review Apple Health access") { Task { await model.connectHealth() } }.disabled(model.refreshing || model.isDemo)
                    Text("Read-only access. Apple Watch records appear through Apple Health; no separate Bluetooth pairing is needed. HealthKit does not disclose read denial.").font(.footnote).foregroundStyle(.secondary)
                }
                Section("Your score goals") {
                    Stepper("Sleep · \(model.goals.sleepHours.formatted()) h", value: Binding(get: { model.goals.sleepHours }, set: { model.goals.sleepHours = $0; model.saveGoals() }), in: 4...12, step: 0.25)
                    Stepper("Steps · \(Int(model.goals.steps).formatted())", value: Binding(get: { model.goals.steps }, set: { model.goals.steps = $0; model.saveGoals() }), in: 1_000...30_000, step: 500)
                    Stepper("Active energy · \(Int(model.goals.activeEnergy)) kcal", value: Binding(get: { model.goals.activeEnergy }, set: { model.goals.activeEnergy = $0; model.saveGoals() }), in: 100...1_500, step: 50)
                    Text("Editable preferences for our experimental scores—not medical recommendations or Oura algorithms. Goal-based Sleep and Activity use live measurements; exports only backfill History.").font(.footnote).foregroundStyle(.secondary)
                }.disabled(model.isDemo)
                Section("Oura historical data") {
                    Link("Request your free Oura account export", destination: URL(string: "https://membership.ouraring.com/data-export")!)
                    Text("Download the export, tap its ZIP in Files to unzip, then import the extracted folder or CSV/JSON files. Official scores, contributors, stress, resilience, naps and other exported fields are available in History. No Oura login is stored in this app.").font(.footnote)
                    Button("Import Oura export") { importing = true }.disabled(model.refreshing)
                    Text("\(model.archiveCount) archived records")
                    if !model.importStatus.isEmpty { Text(model.importStatus).font(.footnote) }
                }
                Section("Preferred source") {
                    ForEach([PersonalMetric.sleep, .restingHR, .hrv, .steps, .energy, .respiratoryRate, .oxygen, .skinTemperature]) { metric in
                        Picker(metric.title, selection: Binding(get: { model.preferences.source(metric) }, set: { model.preferences.priorities[metric.rawValue] = $0; model.savePreferences() })) {
                            ForEach(PersonalSource.allCases) { Text($0.rawValue).tag($0) }
                        }
                    }
                    Text("Each metric uses one source, with the other as fallback. Sleep stages are never combined across sources. Workouts use Apple Watch in this model-free build.").font(.footnote)
                    Text("Sleep-detail metrics follow the selected sleep source. Official Oura scores only come from an imported Oura export.").font(.footnote)
                }
                Section("Recovery weights") {
                    weight("Resting heart rate", path: \.rhrWeight)
                    weight("HRV", path: \.hrvWeight)
                    weight("Sleep duration", path: \.sleepWeight)
                    weight("Deep + REM duration", path: \.stagesWeight)
                    Text("Weights normalize automatically. Baselines use the preceding 30 calendar days and require 14 comparable measurements per component. HRV methods and device identities stay separate.").font(.footnote)
                }
                Section("Privacy") {
                    Text("Read-only Apple Health. Ring records and daily summaries are stored on this iPhone. No app account, backend, API subscription, or iCloud synchronization.")
                    Text("Device backups may include local health files. Diagnostics and manual exports can contain health data.").font(.footnote).foregroundStyle(.secondary)
                }
            }.navigationTitle("Settings")
                .fileImporter(isPresented: $importing, allowedContentTypes: [.folder, .commaSeparatedText, .json, .plainText], allowsMultipleSelection: true) { result in
                    switch result {
                    case .success(let urls): Task { await model.importArchive(urls) }
                    case .failure(let error): model.importStatus = error.localizedDescription
                    }
                }
        }
    }
    private func weight(_ name: String, path: WritableKeyPath<PersonalPreferences, Double>) -> some View {
        VStack(alignment: .leading) {
            Text("\(name) · \(Int(model.preferences[keyPath: path] * 100))")
            Slider(value: Binding(get: { model.preferences[keyPath: path] }, set: { model.preferences[keyPath: path] = $0; model.savePreferences() }), in: 0...1, step: 0.05)
        }
    }
}
struct PersonalRing: View {
    @ObservedObject var model: PersonalDashboardModel
    @ObservedObject var ring: RingSync
    @State private var key = Keychain.loadKey() ?? ""
    @State private var confirmPairing = false
    @AppStorage("ring.measurements.enable-hr") private var enableHR = false
    @AppStorage("ring.measurements.enable-spo2") private var enableSpO2 = false
    @AppStorage("ring.generation") private var generation = RingGeneration.unknown.rawValue
    private var selectedGeneration: RingGeneration { RingGeneration(rawValue: generation) ?? .unknown }
    var body: some View {
        NavigationStack {
            Form {
                Section("Battery") {
                    Label(ring.connectionState.rawValue, systemImage: ring.connectionState == .connected ? "checkmark.circle.fill" : "circle.dotted")
                    if ring.checkingBattery { ProgressView("Refreshing battery…") }
                    if let percent = ring.batteryPercent {
                        Label("\(percent)%", systemImage: ring.batterySymbol).font(.title2)
                        ProgressView(value: Double(percent), total: 100).tint(percent <= 20 ? .orange : .teal)
                        if let time = ring.batteryReadAt { Text("Read from ring \(time.formatted(date: .abbreviated, time: .shortened))").font(.caption) }
                    } else { Text("Battery unavailable until the next successful battery read.") }
                    Button("Refresh battery") { Task { await ring.refreshBattery() } }.disabled(ring.busy || model.isDemo)
                    Text("Battery refreshes on opening the app. The connection indicator describes the current Bluetooth link; a saved percentage is not proof of connection.").font(.footnote).foregroundStyle(.secondary)
                    if !ring.batteryStatus.isEmpty { Text(ring.batteryStatus).font(.caption).foregroundStyle(.secondary) }
                    if ring.lastReport != nil && ring.lastReport?.batteryPercent == nil { Text("The latest sync succeeded, but the ring did not answer the battery request. Any displayed reading is older.").font(.caption) }
                }
                Section("Ring compatibility") {
                    Picker("Your ring model", selection: $generation) {
                        ForEach(RingGeneration.allCases) { Text($0.title).tag($0.rawValue) }
                    }
                    Text(selectedGeneration.supportNote).font(.footnote).foregroundStyle(.secondary)
                    Text("One active ring per installation. This is a manual model selection, not automatic hardware detection.").font(.caption).foregroundStyle(.secondary)
                }
                Section("Connect your ring") {
                    Text("Close Oura and nRF Connect before syncing. Keep your ring nearby, preferably on its charger for the first sync.")
                    SecureField("Pairing key · 32 hex characters", text: $key)
                        .textInputAutocapitalization(.never).autocorrectionDisabled().privacySensitive()
                    Text("Use the existing pairing key for your ring. A new random key will not authenticate an already-onboarded ring.").font(.footnote)
                    Button("Sync ring") {
                        Task {
                            if await ring.run(keyHex: key) != nil { await model.refresh() }
                        }
                    }.disabled(ring.busy || model.refreshing || !selectedGeneration.permitsDirectSync)
                    Button("Pair a factory-reset ring") {
                        confirmPairing = true
                    }
                    .disabled(ring.busy || model.refreshing || !selectedGeneration.permitsPairing)
                    .confirmationDialog("Pair this reset ring?", isPresented: $confirmPairing, titleVisibility: .visible) {
                        Button("Pair ring", role: .destructive) {
                            Task {
                                let newKey = await ring.pair()
                                key = newKey ?? Keychain.loadKey() ?? key
                                guard let newKey else { return }
                                // A successful pairing saves the only copy to this iPhone's
                                // device-only Keychain before returning.
                                if await ring.run(keyHex: newKey) != nil { await model.refresh() }
                            }
                        }
                        Button("Cancel", role: .cancel) { }
                    } message: {
                        Text("This does not reset the ring. Pairing only works after you have synced and backed up in Oura, then factory-reset the ring in the Oura app. Unsynced ring data is erased by that reset. The new key is saved only in this iPhone's Keychain; keep a secure backup of it.")
                    }
                    if ring.busy { ProgressView() }
                    Text(ring.status).font(.footnote)
                }
                Section("Available data") {
                    Toggle("Enable automatic daytime heart rate on sync", isOn: $enableHR)
                    Toggle("Enable automatic blood oxygen on sync", isOn: $enableSpO2)
                    Text("Optional: these standard measurements may be off after a factory reset. Switch on, then Sync ring to request automatic mode. More measurement can reduce battery life. Switching off here stops sending the request; it does not disable a feature already enabled on the ring.").font(.footnote)
                    if !ring.measurementStatus.isEmpty { Text(ring.measurementStatus).font(.caption) }
                    Text("The Bluetooth protocol is independently implemented. Availability depends on firmware and enabled measurements; unverified or missing metrics stay unavailable.")
                    Text("Pairing never resets the ring. Factory reset must be done separately in the Oura app after syncing and backing up. A reset erases data still stored on the ring.").font(.footnote)
                }
            }.navigationTitle("Oura Ring").disabled(model.isDemo)
        }
    }
}
