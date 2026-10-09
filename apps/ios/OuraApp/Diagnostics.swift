import Foundation
import Combine
import Darwin
import MetricKit
import os
import UIKit

@_silgen_name("crashcatch_install")
func crashcatch_install(_ fd: Int32)

/// Bounded local diagnostics. An unfinished session is evidence of interruption,
/// not evidence of a crash. MetricKit payloads retain their original reporting dates.
final class DiagStore: NSObject, ObservableObject, @unchecked Sendable {
    static let shared = DiagStore()
    struct Incident: Identifiable {
        let id: URL
        let date: Date
        let kind: String
        let title: String
        let preview: String
        var body: String { (try? String(contentsOf: id, encoding: .utf8)) ?? "" }
    }
    @Published private(set) var incidents: [Incident] = []
    @Published private(set) var sessions: [Incident] = []
    private let queue = DispatchQueue(label: "md.thomas.openoura.diag", qos: .utility)
    private let pendingLock = NSLock()
    private var pending = 0
    private var dropped = 0
    private var file: FileHandle?
    private var signalFile: FileHandle?
    private var bootstrapped = false
    private var observers: [NSObjectProtocol] = []
    let sessionID = UUID().uuidString
    private var directoryOverride: URL?
    private var lifecycle = "launching"
    private var segmentLimit = 2 * 1024 * 1024
    private var totalLimit = 32 * 1024 * 1024
    private var size = 0
    private var root: URL {
        directoryOverride ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("diagnostics", isDirectory: true)
    }
    private var live: URL { root.appendingPathComponent("session.log") }
    private override init() { super.init() }

    // Isolated diagnostics store for retention/export regression tests.
    init(directory: URL, segmentLimit: Int, totalLimit: Int) {
        super.init()
        self.directoryOverride = directory
        self.segmentLimit = segmentLimit
        self.totalLimit = totalLimit
        for name in ["", "crashes", "sessions"] {
            try? FileManager.default.createDirectory(at: root.appendingPathComponent(name), withIntermediateDirectories: true)
        }
        openLive()
    }

    func bootstrap() {
        queue.sync {
            guard !bootstrapped else { return }
            bootstrapped = true
            let fm = FileManager.default
            for name in ["", "crashes", "sessions"] {
                try? fm.createDirectory(at: root.appendingPathComponent(name), withIntermediateDirectories: true)
            }
            let signal = root.appendingPathComponent("signal.log")
            let marker = (try? String(contentsOf: signal, encoding: .utf8)) ?? ""
            if fm.fileExists(atPath: live.path) {
                let text = (try? String(contentsOf: live, encoding: .utf8)) ?? ""
                let kind = !marker.isEmpty ? "confirmed-crash" : Self.classify(text)
                let dest = root.appendingPathComponent(kind == "backgrounded-session" ? "sessions" : "crashes")
                    .appendingPathComponent("\(kind)-\(UUID().uuidString).log")
                try? fm.moveItem(at: live, to: dest)
                if !marker.isEmpty, let handle = try? FileHandle(forWritingTo: dest) {
                    _ = try? handle.seekToEnd(); try? handle.write(contentsOf: Data(marker.utf8)); try? handle.close()
                }
            }
            fm.createFile(atPath: signal.path, contents: nil)
            signalFile = try? FileHandle(forWritingTo: signal)
            crashcatch_install(signalFile?.fileDescriptor ?? -1)
            openLive()
            prune()
        }
        // Avoid locks, allocation-heavy stack walking, or re-entering the logger in an exception handler.
        NSSetUncaughtExceptionHandler { _ in
            let marker = "\n*** EXCEPTION ***\n"
            marker.withCString { p in
                if let fd = DiagStore.shared.signalFile?.fileDescriptor { _ = Darwin.write(fd, p, strlen(p)) }
            }
        }
        MXMetricManager.shared.add(self)
        let center = NotificationCenter.default
        for (name, state) in [(UIApplication.didEnterBackgroundNotification, "background"),
                              (UIApplication.didBecomeActiveNotification, "active"),
                              (UIApplication.protectedDataWillBecomeUnavailableNotification, "protected-data-unavailable"),
                              (UIApplication.protectedDataDidBecomeAvailableNotification, "protected-data-available"),
                              (UIApplication.didReceiveMemoryWarningNotification, "memory-warning")] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { _ in
                dlog("lifecycle", "state=\(state)")
                memLog(state)
                self.flush()
            })
        }
        refreshLists()
        dlog("diag", "session started id=\(sessionID)")
    }

    static func classify(_ text: String) -> String {
        if text.contains("*** CRASH ***") || text.contains("*** EXCEPTION ***") { return "confirmed-crash" }
        let states = text.split(separator: "\n").filter { $0.contains("[lifecycle]") }
        if states.last(where: { $0.contains("state=background") || $0.contains("state=active") })?.contains("state=background") == true {
            return "backgrounded-session"
        }
        return "interrupted-session-cause-unknown"
    }

    func append(_ line: String) {
        pendingLock.lock()
        guard pending < 256 else { dropped += 1; pendingLock.unlock(); return }
        pending += 1
        pendingLock.unlock()
        queue.async {
            defer { self.pendingLock.lock(); self.pending -= 1; self.pendingLock.unlock() }
            self.pendingLock.lock(); let omitted = self.dropped; self.dropped = 0; self.pendingLock.unlock()
            if line.contains("[lifecycle]") {
                if line.contains("state=background") { self.lifecycle = "background" }
                if line.contains("state=active") { self.lifecycle = "active" }
            }
            let bounded = String(line.prefix(8192))
            let data = Data(((omitted > 0 ? "[diag] omitted \(omitted) queued records\n" : "") + bounded + "\n").utf8)
            if self.size + data.count > self.segmentLimit { self.rotate() }
            do { try self.file?.write(contentsOf: data); self.size += data.count }
            catch { /* Diagnostics must not crash or recursively log disk failures. */ }
            if line.contains(" error [sync]") || line.contains(" error [db]") || line.contains(" error [models]") {
                let url = self.root.appendingPathComponent("crashes/operation-failure_\(UUID().uuidString).log")
                try? data.write(to: url, options: .atomic)
                self.prune(); self.refreshLists()
            }
        }
    }

    func flush() { queue.sync { try? file?.synchronize() } }

    private func openLive() {
        FileManager.default.createFile(atPath: live.path, contents: nil)
        file = try? FileHandle(forWritingTo: live)
        let header = "Open Oura \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] ?? "?") (\(Bundle.main.infoDictionary?["CFBundleVersion"] ?? "?"))\n\(ProcessInfo.processInfo.operatingSystemVersionString)\nsession=\(sessionID) started=\(ISO8601DateFormatter().string(from: Date())) core=\(coreVersion())\n[lifecycle] state=\(lifecycle)\n"
        let data = Data(header.utf8)
        try? file?.write(contentsOf: data); size = data.count
    }
    private func rotate() {
        try? file?.synchronize(); try? file?.close(); file = nil
        let dest = root.appendingPathComponent("sessions/segment-\(UUID().uuidString).log")
        try? FileManager.default.moveItem(at: live, to: dest)
        openLive(); prune()
    }
    private func prune() {
        let fm = FileManager.default
        let files = ["crashes", "sessions"].flatMap {
            (try? fm.contentsOfDirectory(at: root.appendingPathComponent($0), includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey])) ?? []
        }.sorted { date($0) > date($1) }
        var bytes = segmentLimit
        for (index, url) in files.enumerated() {
            bytes += (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            if bytes > totalLimit || index >= 32 { try? fm.removeItem(at: url) }
        }
    }
    private func date(_ url: URL) -> Date {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
    }
    private func refreshLists() {
        queue.async {
            let incidents = self.loadFolder("crashes")
            let sessions = self.loadFolder("sessions")
            DispatchQueue.main.async { self.incidents = incidents; self.sessions = sessions }
        }
    }
    private func loadFolder(_ folder: String) -> [Incident] {
        let files = (try? FileManager.default.contentsOfDirectory(at: root.appendingPathComponent(folder), includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        return files.map { url in
            let body = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
            let name = url.lastPathComponent
            let kind: String
            if name.hasPrefix("operation-failure") { kind = "operation-failure" }
            else if name.hasPrefix("metrickit") { kind = name.components(separatedBy: "_")[0] }
            else { kind = Self.classify(body) }
            return Incident(id: url, date: date(url), kind: kind, title: kind,
                            preview: Self.incidentPreview(body, kind: kind))
        }.sorted { $0.date > $1.date }
    }

    static func incidentPreview(_ body: String, kind: String) -> String {
        let lines = body.split(separator: "\n")
        if kind == "operation-failure" {
            // A Torch exception can end with dozens of stack frames. Keep its
            // leading cause and input context in the summary; full exports retain
            // the trace. Older records can include a dropped-record notice first.
            let start = lines.firstIndex { $0.contains(" error [") } ?? lines.startIndex
            return lines.dropFirst(start).prefix(4).joined(separator: "\n")
        }
        return lines.suffix(4).joined(separator: "\n")
    }
    func exportSummary() -> String {
        flush()
        let reports = queue.sync { loadFolder("crashes") }
        let recent = reports.prefix(5)
        let groups = Dictionary(grouping: reports, by: { report in
            if let match = report.preview.range(of: "sqlite=[0-9]+", options: .regularExpression) {
                return "storage " + String(report.preview[match])
            }
            if report.preview.lowercased().contains("auth") { return "authentication failure" }
            if report.preview.lowercased().contains("timeout") { return "transport timeout" }
            return report.kind
        }).map { "\($0.key): \($0.value.count)" }.sorted()
        return RingDiag.shared.summary() + "\n\nRetained incidents: \(reports.count); included: \(recent.count)\n"
            + groups.joined(separator: "\n") + "\n" + recent.map { "\($0.title): \($0.preview)" }.joined(separator: "\n")
    }
    func exportAll() -> String {
        flush()
        let clock = ClockReport.text().map { "\n--- ring clock ---\n\($0)\n" } ?? ""
        return queue.sync {
            let current = (try? String(contentsOf: live, encoding: .utf8)) ?? ""
            let retained = loadFolder("crashes") + loadFolder("sessions")
            return current + clock + "\nRetained reports included: \(retained.count)/\(retained.count)\n"
                + retained.map { "\n--- \($0.kind) ---\n\($0.body)" }.joined()
        }
    }
    func exportFile() -> URL? {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("oura-diagnostics.txt")
        do { try exportAll().write(to: url, atomically: true, encoding: .utf8); return url }
        catch { return nil }
    }
    private func record(_ kind: String, data: Data, incident: Bool = true) {
        queue.async {
            // Retain original diagnostic payload; never append a delayed crash to the live session.
            let folder = incident ? "crashes" : "sessions"
            let dest = self.root.appendingPathComponent("\(folder)/\(kind)_\(UUID().uuidString).json")
            if data.count <= self.totalLimit / 2 { try? data.write(to: dest, options: .atomic) }
            else {
                let note = Data("{\"omitted_payload_bytes\":\(data.count),\"reason\":\"local diagnostics size limit\"}".utf8)
                try? note.write(to: dest, options: .atomic)
            }
            self.prune(); self.refreshLists()
        }
    }
}
extension DiagStore: MXMetricManagerSubscriber {
    func didReceive(_ payloads: [MXMetricPayload]) {
        for payload in payloads { record("metrickit-metrics-reporting-period", data: payload.jsonRepresentation(), incident: false) }
    }
    func didReceive(_ payloads: [MXDiagnosticPayload]) {
        for payload in payloads {
            let kind = !(payload.crashDiagnostics ?? []).isEmpty ? "metrickit-confirmed-crash"
                : (!(payload.hangDiagnostics ?? []).isEmpty ? "metrickit-hang" : "metrickit-resource-diagnostic")
            record(kind, data: payload.jsonRepresentation())
        }
    }
}
