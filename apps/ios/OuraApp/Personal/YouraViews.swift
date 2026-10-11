import SwiftUI
import Charts
import AVFoundation

enum YouraStyle {
    static let launchBackground = Color(red: 0.075, green: 0.086, blue: 0.10)
    static let tint = Color(uiColor: UIColor { traits in
        traits.userInterfaceStyle == .dark ? UIColor(red: 0.48, green: 0.78, blue: 0.96, alpha: 1) : UIColor(red: 0.12, green: 0.38, blue: 0.57, alpha: 1)
    })
}
struct YouraMorningBrief: View {
    let insights: YouraInsightSnapshot
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Morning Brief").font(.headline)
            ForEach(Array(insights.brief.prefix(2).enumerated()), id: \.offset) { _, line in Text(line).font(.subheadline).fixedSize(horizontal: false, vertical: true) }
        }.padding(.vertical, 6)
    }
}
struct YouraPatternsView: View {
    @ObservedObject var model: PersonalDashboardModel
    private var supported: [PatternInsight] { model.insights.patterns.filter(\.supported) }
    var body: some View {
        List {
            if model.isDemo { Section { Label("Demo · synthetic data", systemImage: "testtube.2").font(.caption) } }
            Section("What your nights suggest") {
                if supported.isEmpty { Text("Patterns need five comparable nights on each side. Confirm habits in Talk to Youra to start building evidence.").foregroundStyle(.secondary) }
                ForEach(supported) { pattern in NavigationLink { YouraPatternDetail(pattern: pattern) } label: {
                    VStack(alignment: .leading, spacing: 5) {
                        Text(pattern.title + " · " + pattern.metric.title).font(.headline)
                        Text(pattern.explanation).font(.subheadline).foregroundStyle(.secondary)
                        Text("\(pattern.evidence.count) nights · \(pattern.source)").font(.caption).foregroundStyle(.secondary)
                    }.padding(.vertical, 5)
                } }
            }
            if let hr = model.insights.hr {
                Section("Overnight heart-rate shape") {
                    if let date = model.insights.latestDate { Text(date.formatted(date: .abbreviated, time: .omitted)).font(.caption).foregroundStyle(.secondary) }
                    LabeledContent("First third · median", value: PersonalDisplay.value(hr.firstMedian, metric: .averageHR))
                    LabeledContent("Last third · median", value: PersonalDisplay.value(hr.lastMedian, metric: .averageHR))
                    LabeledContent("Lowest 15-minute median", value: PersonalDisplay.value(hr.lowestMedian, metric: .averageHR))
                    if let time = hr.lowestWindow { LabeledContent("Window started", value: time.formatted(date: .omitted, time: .shortened)) }
                    Text(model.insights.context.source).font(.caption).foregroundStyle(.secondary)
                    Text("Uses actual timestamps, not stretched samples. Sparse windows stay unavailable; sleep stages and other factors can affect heart rate.").font(.footnote).foregroundStyle(.secondary)
                }
            }
            Section("Building evidence") {
                if model.insights.patterns.isEmpty { Text("Sync a complete night first. Imported account exports do not contribute to live patterns.").foregroundStyle(.secondary) }
                ForEach(model.insights.patterns.filter { !$0.supported }) { pattern in
                    NavigationLink { YouraPatternDetail(pattern: pattern) } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(pattern.title + " · " + pattern.metric.title)
                            Text(pattern.explanation).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            Section { Text("60-day comparisons, one comparable sleep source and device. Unknown habits and incomplete nights are excluded. These are personal associations—not proof of cause, diagnoses, or official Oura scores.").font(.footnote).foregroundStyle(.secondary) }
        }.navigationTitle("Patterns").navigationBarTitleDisplayMode(.inline)
    }
}
struct YouraPatternDetail: View {
    let pattern: PatternInsight
    @Environment(\.dynamicTypeSize) private var textSize
    var body: some View {
        List {
            Section {
                Text(pattern.title).font(.title2.weight(.semibold))
                Text(pattern.explanation)
                Text(pattern.source).font(.subheadline).foregroundStyle(.secondary)
                if pattern.id.hasPrefix("schedule-") { Text("Clock offsets are minutes relative to the latest comparable night, unwrapped across midnight. Negative means earlier. This is not a sleep-regularity index.").font(.footnote) }
            }
            Section("Recorded nights") {
                if !pattern.evidence.isEmpty {
                    Chart(pattern.evidence) { row in
                        PointMark(x: .value("Wake date", row.date), y: .value("Value", row.value))
                            .foregroundStyle(by: .value("Group", row.group))
                    }
                    .chartXAxis {
                        AxisMarks(values: [pattern.evidence.map(\.date).min()!, pattern.evidence.map(\.date).max()!]) {
                            AxisGridLine(); AxisValueLabel(format: .dateTime.month(.abbreviated).day()).font(.caption)
                        }
                    }
                    .chartYAxis { AxisMarks(values: .automatic(desiredCount: 3)) { AxisGridLine(); AxisValueLabel().font(.caption) } }
                    .chartYAxisLabel(pattern.id.hasPrefix("schedule-") ? "Clock offset (min)" : PersonalDisplay.unit(pattern.metric))
                    .frame(height: textSize.isAccessibilitySize ? 340 : 210)
                }
                ForEach([pattern.groupA, pattern.groupB], id: \.self) { group in
                    let rows = pattern.evidence.filter { $0.group == group }
                    LabeledContent(group, value: "\(rows.count) nights")
                    if rows.count >= 5 { LabeledContent("Median", value: PersonalDisplay.value(YouraInsights.median(rows.map(\.value)), metric: pattern.metric)) }
                }
                ForEach(pattern.evidence.sorted { $0.date > $1.date }) { row in
                    VStack(alignment: .leading, spacing: 4) {
                        LabeledContent(row.date.formatted(date: .abbreviated, time: .omitted), value: PersonalDisplay.value(row.value, metric: pattern.metric))
                        Text(row.group).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            Section("How to read this") {
                Text("A difference between medians is descriptive. Timing, travel, illness, unlogged habits, and other factors can explain it. Five nights per group is a display threshold, not statistical or clinical validation.").font(.footnote)
                if pattern.id.hasPrefix("workout-") { Text("Only nights with a recorded workout ending in the previous 24 hours are compared. This does not measure intensity and never treats missing workout records as a rest day.").font(.footnote) }
            }
        }.navigationTitle(pattern.metric.title).navigationBarTitleDisplayMode(.inline)
    }
}

struct YouraTalkView: View {
    @ObservedObject var model: PersonalDashboardModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var phase
    @StateObject private var speech = YouraSpeech()
    @State private var text = ""
    @State private var date: Date
    @State private var draft: VoiceJournalDraft?
    @State private var mode = 0
    @State private var includeNight = true
    @State private var includeJournal = false
    @State private var includePriorReply = false
    @State private var selectedPatterns = Set<String>()
    @State private var muted = false
    @State private var reply = ""
    @State private var status = ""
    @State private var sending = false
    @State private var sendTask: Task<Void, Never>?
    @State private var approvedPreview: String?
    @AppStorage("youra.hermes.url") private var server = ""
    @AppStorage("youra.hermes.model") private var serverModel = "hermes-agent"
    init(model: PersonalDashboardModel, date: Date) {
        self.model = model
        let calendar = Calendar.current
        let next = calendar.isDateInToday(date) && calendar.component(.hour, from: Date()) >= 12
            ? calendar.date(byAdding: .day, value: 1, to: date) ?? date : date
        _date = State(initialValue: calendar.startOfDay(for: next))
    }
    private var preview: String {
        var parts = ["Message:\n" + text.trimmingCharacters(in: .whitespacesAndNewlines)]
        if includeNight { parts.append("Selected latest valid night:\n" + model.insights.context.preview) }
        if includeJournal {
            let entries = model.journal.filter { Calendar.current.isDate($0.nightDate, inSameDayAs: date) && $0.answer != .unknown }
            parts.append("Confirmed check-in for wake date \(date.formatted(date: .abbreviated, time: .omitted)):\n" + entries.map {
                "\($0.habit.title): \($0.answer.rawValue)" + ($0.time.map { " · " + $0.formatted(date: .abbreviated, time: .shortened) } ?? " · time unknown")
            }.joined(separator: "\n"))
        }
        if includePriorReply && !reply.isEmpty { parts.append("Previous assistant reply (not verified measurements):\n" + reply) }
        for pattern in model.insights.patterns where selectedPatterns.contains(pattern.id) && pattern.supported {
            parts.append("Selected 60-day pattern: \(pattern.title) · \(pattern.metric.title) · \(pattern.source)\n\(pattern.explanation) \(pattern.a.count) \(pattern.groupA) nights / \(pattern.b.count) \(pattern.groupB) nights. Descriptive association, not causation.")
        }
        return parts.joined(separator: "\n\n")
    }
    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Talk mode", selection: $mode) { Text("Check-in").tag(0); Text("Hermes").tag(1) }.pickerStyle(.segmented)
                    DatePicker("Wake-up date for habits", selection: $date, displayedComponents: .date)
                    Text("Choose the date you wake after these habits. Evening check-ins normally belong to tomorrow’s sleep.").font(.footnote).foregroundStyle(.secondary)
                }
                Section("Say it your way") {
                    TextEditor(text: $text).frame(minHeight: 110).accessibilityLabel("Transcript or typed message")
                        .overlay(alignment: .topLeading) { if text.isEmpty { Text("Type here, or record a check-in.").foregroundStyle(.secondary).padding(.top, 8).allowsHitTesting(false).accessibilityHidden(true) } }
                    if speech.recording { Button("Finish recording", systemImage: "stop.circle.fill") { speech.stop(); text = speech.transcript } }
                    else { Button(speech.preparing ? "Preparing microphone…" : "Record a short turn", systemImage: "mic.fill") { Task { await speech.start() } }.disabled(speech.preparing || sending) }
                    if !speech.status.isEmpty { Text(speech.status).font(.footnote).foregroundStyle(.secondary) }
                    Text("English transcription stays on this device. No recordings are saved. Typing always works.").font(.footnote).foregroundStyle(.secondary)
                    if text.count > 16_000 { Text("This turn is too long. Shorten it to 16,000 characters before reviewing.").font(.footnote) }
                }
                if mode == 0 {
                    Section {
                        Button("Review check-in", systemImage: "checklist") {
                            speech.stop(); speech.silence()
                            draft = VoiceJournalDraft.parse(text, date: date)
                            if let question = draft?.questions.first, !muted { speech.speak(question) }
                        }.disabled(speech.recording || speech.preparing || text.count > 16_000 || text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        Button("Review or edit this date’s saved check-in") {
                            var saved = VoiceJournalDraft.empty(date: date)
                            for i in saved.entries.indices {
                                if let e = model.journal.last(where: { $0.habit == saved.entries[i].habit && Calendar.current.isDate($0.nightDate, inSameDayAs: date) }) { saved.entries[i] = e }
                            }
                            draft = saved
                        }.disabled(speech.recording || speech.preparing)
                        if !model.journalStatus.isEmpty { Text(model.journalStatus).font(.footnote) }
                    }
                } else {
                    Section("Context you choose") {
                        Toggle("Include latest valid night", isOn: $includeNight)
                        Toggle("Include confirmed check-in for this date", isOn: $includeJournal)
                        if !reply.isEmpty { Toggle("Include previous reply for follow-up", isOn: $includePriorReply) }
                        DisclosureGroup("Select supported pattern summaries") {
                            if !model.insights.patterns.contains(where: \.supported) { Text("No supported patterns yet.").foregroundStyle(.secondary) }
                            ForEach(model.insights.patterns.filter(\.supported)) { pattern in
                                Toggle(pattern.title + " · " + pattern.metric.title, isOn: Binding(get: { selectedPatterns.contains(pattern.id) }, set: { selected in
                                    if selected { selectedPatterns.insert(pattern.id) } else { selectedPatterns.remove(pattern.id) }
                                }))
                            }
                        }
                        Text("No other nights, raw samples, pairing keys, ring identifiers, or journal history are included.").font(.footnote).foregroundStyle(.secondary)
                    }
                    Section {
                        if server.isEmpty { NavigationLink("Set up your Hermes server") { YouraHermesSettings(onDailyBriefEnabled: { await model.sendDailyBriefAfterOuraSync() }) } }
                        Button("Review message & context", systemImage: "paperplane") { speech.silence(); approvedPreview = preview }
                            .disabled(server.isEmpty || speech.recording || speech.preparing || sending || text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        if sending { ProgressView("Waiting for Hermes…"); Button("Cancel request", role: .cancel) { sendTask?.cancel() } }
                        if !status.isEmpty { Text(status).font(.footnote) }
                    }
                    if !reply.isEmpty {
                        Section("Hermes reply · AI-generated") {
                            Text(reply).textSelection(.enabled)
                            Button("Read reply aloud", systemImage: "speaker.wave.2") { speech.speak(reply) }.disabled(speech.recording || speech.preparing || muted)
                            Button("Use my message as a journal draft") { mode = 0; draft = VoiceJournalDraft.parse(text, date: date) }
                            Text("An explanation, not a diagnosis or a new measurement. Nothing in this reply changes your records.").font(.footnote).foregroundStyle(.secondary)
                        }
                    }
                }
                Section { Toggle("Mute spoken replies", isOn: $muted) }
            }.navigationTitle("Talk to Youra").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } } }
                .onChange(of: speech.transcript) { _, value in if speech.recording { text = value } }
                .onChange(of: muted) { _, value in if value { speech.silence() } }
                .onChange(of: phase) { _, value in if value != .active { speech.stop(); speech.silence(); sendTask?.cancel() } }
                .onReceive(NotificationCenter.default.publisher(for: AVAudioSession.interruptionNotification)) { _ in speech.stop(); speech.silence(); speech.status = "Audio was interrupted. Review your text or record another turn." }
                .onDisappear { speech.stop(); speech.silence(); sendTask?.cancel() }
                .sheet(item: Binding(get: { draft.map { YouraDraftSheetValue(draft: $0) } }, set: { draft = $0?.draft })) { value in
                    YouraJournalReview(model: model, draft: value.draft)
                }
                .sheet(isPresented: Binding(get: { approvedPreview != nil }, set: { if !$0 { approvedPreview = nil } })) {
                    NavigationStack {
                        List {
                            Section("Exactly what will be sent") { Text(approvedPreview ?? "").textSelection(.enabled) }
                            Section { Text("Destination: \(server). The server and its model provider may retain text and charge for processing. No audio is sent. Server-side tools must be disabled using the setup guide.").font(.footnote) }
                            Section { DisclosureGroup("Assistant instructions also sent") { Text(HermesClient.instructions).font(.footnote) } }
                        }.navigationTitle("Review & send").navigationBarTitleDisplayMode(.inline)
                            .toolbar {
                                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { approvedPreview = nil } }
                                ToolbarItem(placement: .confirmationAction) { Button("Send") { if let approvedPreview { send(approvedPreview) }; approvedPreview = nil } }
                            }
                    }
                }
        }.tint(YouraStyle.tint)
    }
    private func send(_ preview: String) {
        guard !sending else { return }
        sending = true; status = ""
        let configuration = HermesConfiguration(baseURL: server, model: serverModel)
        let token = HermesCredential.load() ?? ""
        sendTask = Task { @MainActor in
            defer { sending = false; sendTask = nil }
            do {
                let response = try await HermesClient().send(configuration: configuration, token: token, preview: preview)
                try Task.checkCancellation(); reply = response
                if !muted { speech.speak(response) }
            } catch is CancellationError { status = "Request cancelled. Cancellation cannot recall text already received by your server." }
            catch { status = error.localizedDescription }
        }
    }
}
private struct YouraDraftSheetValue: Identifiable { var id: Date { draft.nightDate }; let draft: VoiceJournalDraft }
struct YouraJournalReview: View {
    @ObservedObject var model: PersonalDashboardModel
    @State var draft: VoiceJournalDraft
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var phase
    @StateObject private var followup = YouraSpeech()
    @State private var followupText = ""
    @State private var followupHabit = YouraHabit.caffeine
    var body: some View {
        NavigationStack {
            Form {
                Section {
                    DatePicker("Wake-up date", selection: $draft.nightDate, displayedComponents: .date)
                    Text("These proposed entries are not saved yet. Review every answer; leave anything uncertain unknown.").font(.footnote)
                }
                if !draft.questions.isEmpty { Section("Please clarify") { ForEach(draft.questions, id: \.self) { Text($0).font(.subheadline) } } }
                Section("Answer a follow-up by voice") {
                    Picker("Answer about", selection: $followupHabit) { ForEach(YouraHabit.allCases) { Text($0.title).tag($0) } }
                    Text("Say Yes, No, or Unknown—or a full phrase such as ‘coffee at 4 PM’. Review the proposed answer below.").font(.footnote).foregroundStyle(.secondary)
                    TextEditor(text: $followupText).frame(minHeight: 65).accessibilityLabel("Follow-up transcript")
                    if followup.recording { Button("Finish answer", systemImage: "stop.circle") { followup.stop(); followupText = followup.transcript } }
                    else { Button("Record answer", systemImage: "mic") { Task { await followup.start() } }.disabled(followup.preparing) }
                    if !followup.status.isEmpty { Text(followup.status).font(.footnote) }
                    Button("Apply answer to draft") {
                        draft = draft.applyingFollowup(followupText, habit: followupHabit)
                        followupText = ""
                    }.disabled(followup.recording || followup.preparing || followupText.isEmpty)
                }
                ForEach(draft.entries.indices, id: \.self) { i in
                    Section(draft.entries[i].habit.title) {
                        Picker("Answer", selection: $draft.entries[i].answer) { ForEach(HabitAnswer.allCases, id: \.self) { Text($0.rawValue).tag($0) } }.pickerStyle(.segmented)
                        if draft.entries[i].answer == .yes && draft.entries[i].habit != .freeDay {
                            Toggle("Add a time", isOn: Binding(get: { draft.entries[i].time != nil }, set: { draft.entries[i].time = $0 ? Calendar.current.date(byAdding: .day, value: -1, to: draft.nightDate) : nil }))
                            if draft.entries[i].time != nil { DatePicker("Event date & time", selection: Binding(get: { draft.entries[i].time ?? draft.nightDate }, set: { draft.entries[i].time = $0 })) }
                        }
                    }
                }
                Section { Text("Free day: Yes means free day; No means work day. Unknown stays out of schedule comparisons.").font(.footnote).foregroundStyle(.secondary) }
                if !model.journalStatus.isEmpty { Section { Text(model.journalStatus).font(.footnote) } }
            }.disabled(model.journalSaving)
                .onChange(of: followup.transcript) { _, value in if followup.recording { followupText = value } }
                .onChange(of: phase) { _, value in if value != .active { followup.stop() } }
                .onReceive(NotificationCenter.default.publisher(for: AVAudioSession.interruptionNotification)) { _ in followup.stop() }
                .onDisappear { followup.stop(); followup.silence() }
                .navigationTitle("Confirm check-in").navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() }.disabled(model.journalSaving) }
                    ToolbarItem(placement: .confirmationAction) { Button(model.journalSaving ? "Saving…" : "Save") {
                        for i in draft.entries.indices where draft.entries[i].answer != .yes { draft.entries[i].time = nil }
                        Task { if await model.saveJournal(draft) { dismiss() } }
                    }.disabled(model.journalSaving || followup.recording || followup.preparing) }
                }.interactiveDismissDisabled(model.journalSaving)
        }
    }
}

struct YouraHermesSettings: View {
    var onDailyBriefEnabled: (() async -> Void)? = nil
    @AppStorage("youra.hermes.url") private var server = ""
    @AppStorage("youra.hermes.model") private var model = "youra"
    @AppStorage("youra.dailyBrief.enabled") private var dailyBriefEnabled = false
    @AppStorage("youra.dailyBrief.status") private var dailyBriefStatus = ""
    @State private var token = ""
    @State private var status = ""
    @State private var testing = false
    @State private var configured = false
    var body: some View {
        Form {
            Section("Private voice check-ins") { Text("Check-ins work without Hermes. English microphone transcription uses on-device recognition only. If it’s unavailable, type instead. Review proposed habits before saving.") }
            Section("Your own Hermes server") {
                TextField("HTTPS API base URL", text: $server).keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                TextField("Model", text: $model).textInputAutocapitalization(.never).autocorrectionDisabled()
                SecureField(configured ? "New token (leave empty to keep saved token)" : "Bearer token", text: $token).textInputAutocapitalization(.never).autocorrectionDisabled().privacySensitive()
                Button("Save token securely") {
                    do { guard !token.isEmpty else { status = "Enter a token, or keep your existing token unchanged."; return }; try HermesCredential.save(token); token = ""; configured = true; status = "Token saved in this iPhone’s Keychain." }
                    catch { status = "Couldn’t save the token securely. Try again when this iPhone is unlocked." }
                }.disabled(testing)
                Button("Test connection · no health data") {
                    testing = true; status = "Checking API metadata…"
                    Task {
                        defer { testing = false }
                        do { try await HermesClient().test(configuration: .init(baseURL: server, model: model), token: HermesCredential.load() ?? ""); status = "API metadata received. This does not verify tool restrictions or model availability." }
                        catch { status = error.localizedDescription }
                    }
                }.disabled(testing || server.isEmpty || !configured)
                if testing { ProgressView() }
                if !status.isEmpty { Text(status).font(.footnote) }
                Button("Remove saved token", role: .destructive) { try? HermesCredential.save(""); configured = false; status = "Hermes token removed. Ring pairing is unchanged." }.disabled(testing || !configured)
            }
            Section("Daily iMessage") {
                Toggle("Send my sleep brief", isOn: Binding(get: { dailyBriefEnabled }, set: { enabled in
                    dailyBriefEnabled = enabled
                    if enabled, let onDailyBriefEnabled { Task { await onDailyBriefEnabled() } }
                })).disabled(server.isEmpty || !configured)
                if dailyBriefEnabled {
                    Text("Your Mac sends a short AI-written iMessage 10 minutes after the wake time recorded by Oura. Youra must sync that complete Oura night before then; otherwise the message is skipped.").font(.footnote)
                    DisclosureGroup("What leaves this iPhone") {
                        Text("Only the complete direct Bluetooth sleep summary: sleep and bed duration, efficiency, latency, stage totals, awakenings, and sleep/wake times. Never Apple Health sleep, imported exports, journal entries, ring identifiers, or raw samples. Your private Hermes profile must be running and tools remain disabled.").font(.footnote)
                        Text("The summary is sent over your private HTTPS tailnet to your Mac. The model/provider may retain it; Photon delivers the message to the iMessage destination already configured on that Mac.").font(.footnote)
                    }
                    if !dailyBriefStatus.isEmpty { Text(dailyBriefStatus).font(.caption).foregroundStyle(.secondary) }
                }
            }
            Section("Before connecting") {
                Text("Use a dedicated Hermes profile with tools and external integrations disabled. The app cannot enforce restrictions on someone else’s server. Instructions alone are not a security boundary.")
                Link("Youra Hermes setup & privacy guide", destination: URL(string: "https://github.com/ytolba/StrictlyHealth/blob/main/docs/public/HERMES.md")!)
                Text("An iPhone’s localhost is the phone, not your Mac. Use a reachable HTTPS hostname with a trusted certificate. No insecure HTTP exceptions are provided.").font(.footnote)
            }
            Section("You control sharing") {
                Text("AI chats are sent only after Review & Send. Daily sleep messages are optional and use only the direct Oura summary described above. No audio, raw ring records, pairing keys or full journal database are uploaded.")
                Text("This is optional AI explanation—not medical advice or an official Oura service.").font(.footnote).foregroundStyle(.secondary)
            }
        }.navigationTitle("AI & Messages").navigationBarTitleDisplayMode(.inline)
            .onAppear {
                configured = HermesCredential.load() != nil
                if model == "hermes-agent" { model = "youra" }
            }
    }
}
