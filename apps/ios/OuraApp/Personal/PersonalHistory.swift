import SwiftUI

struct PersonalHistory: View {
    @ObservedObject var model: PersonalDashboardModel
    @State private var selection = Date()
    private var selected: PersonalDay? { model.days.first { Calendar.current.isDate($0.date, inSameDayAs: selection) } }
    var body: some View {
        NavigationStack {
            List {
                DatePicker("Date", selection: $selection, in: ...Date(), displayedComponents: .date)
                if let day = selected {
                    if let night = day.night { Section("Sleep") { NavigationLink("Sleep stages, times & awakenings") { PersonalSleepDetail(night: night) } } }
                    Section("Measurements") {
                        ForEach(PersonalMetric.allCases) { metric in
                            if let value = day.value(metric) {
                                VStack(alignment: .leading) {
                                    LabeledContent(metric.title, value: PersonalDisplay.value(value.value, metric: metric))
                                    Text([value.source.rawValue, value.method].compactMap { $0 }.joined(separator: " · ")).font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        }
                        if day.values.isEmpty { Text("No measurements for this date.") }
                    }
                    if let records = day.archiveRecords, !records.isEmpty {
                        Section("Oura archive") { NavigationLink("All metrics, contributors & sessions (\(records.count))") { PersonalArchiveDetail(records: records) } }
                    }
                } else { Text("No stored data for this date. Import your Oura export in Settings for older history.") }
                Section("Recorded days") {
                    ForEach(model.days.filter { !$0.values.isEmpty || !($0.archiveRecords ?? []).isEmpty }.reversed()) { day in
                        Button(day.date.formatted(date: .abbreviated, time: .omitted)) { selection = day.date }
                    }
                }
            }.navigationTitle("History")
        }
    }
}

struct PersonalArchiveDetail: View {
    let records: [PersonalArchiveRecord]
    var body: some View {
        List {
            Section { Text("Original Oura account export. Durations in raw fields are seconds unless Oura specifies otherwise. These are imported results, not new Bluetooth calculations.").font(.footnote) }
            ForEach(records) { record in
                Section(record.table + " · " + (record.fields["type"] ?? record.day)) {
                    if let night = PersonalArchive.night(record) { NavigationLink("Sleep session detail") { PersonalSleepDetail(night: night) } }
                    ForEach(record.fields.keys.sorted(), id: \.self) { key in
                        DisclosureGroup(key.replacingOccurrences(of: "_", with: " ").capitalized) {
                            Text(record.fields[key] ?? "").font(.caption.monospaced()).textSelection(.enabled)
                        }
                    }
                }
            }
        }.navigationTitle("Oura export details")
    }
}
