import Foundation
import HealthKit

struct PersonalHealthSnapshot {
    var samples: [String: [HKSample]] = [:]
    var totals: [String: [Date: PersonalValue]] = [:]
}

// HKHealthStore supports background queries. Observer state stays on MainActor;
// fetch only touches the immutable store and its own local snapshot.
final class PersonalHealthReader: @unchecked Sendable {
    private let store = HKHealthStore()
    @MainActor private var observers: [HKObserverQuery] = []
    @MainActor private var updates: [HKAnchoredObjectQuery] = []
    @MainActor private var anchors: [String: HKQueryAnchor] = [:]
    @MainActor var onChange: (() -> Void)?
    private let identifiers: [HKQuantityTypeIdentifier] = [
        .heartRate, .restingHeartRate, .heartRateVariabilitySDNN, .stepCount, .activeEnergyBurned,
        .respiratoryRate, .oxygenSaturation, .appleSleepingWristTemperature
    ]
    var types: Set<HKSampleType> {
        var result = Set(identifiers.compactMap { HKObjectType.quantityType(forIdentifier: $0) }.map { $0 as HKSampleType })
        result.insert(HKObjectType.categoryType(forIdentifier: .sleepAnalysis)!)
        result.insert(HKObjectType.workoutType())
        return result
    }
    func authorize() async throws {
        guard HKHealthStore.isHealthDataAvailable() else {
            throw NSError(domain: "PersonalHealth", code: 1, userInfo: [NSLocalizedDescriptionKey: "HealthKit is unavailable on this device."])
        }
        try await store.requestAuthorization(toShare: [], read: Set(types.map { $0 as HKObjectType }))
    }
    @MainActor func observe() {
        guard observers.isEmpty else { return }
        for type in types {
            let query = HKObserverQuery(sampleType: type, predicate: nil) { [weak self] _, completion, error in
                // The observer only invalidates the display; querying happens in refresh.
                if error == nil { DispatchQueue.main.async { self?.onChange?() } }
                completion()
            }
            observers.append(query); store.execute(query)
            // Delivery is best-effort; iOS controls scheduling and may defer it.
            store.enableBackgroundDelivery(for: type, frequency: .hourly) { _, _ in }
            let cutoff = Calendar.current.date(byAdding: .day, value: -120, to: Date())!
            let anchored = HKAnchoredObjectQuery(type: type,
                predicate: HKQuery.predicateForSamples(withStart: cutoff, end: nil),
                anchor: anchors[type.identifier], limit: HKObjectQueryNoLimit) { [weak self] _, _, _, anchor, error in
                    DispatchQueue.main.async {
                        guard let self, error == nil else { return }
                        self.anchors[type.identifier] = anchor
                    }
                }
            anchored.updateHandler = { [weak self] _, added, deleted, anchor, error in
                DispatchQueue.main.async {
                    guard let self, error == nil else { return }
                    self.anchors[type.identifier] = anchor
                    if !(added ?? []).isEmpty || !(deleted ?? []).isEmpty { self.onChange?() }
                }
            }
            updates.append(anchored); store.execute(anchored)
        }
    }
    func fetch(start: Date, end: Date) async throws -> PersonalHealthSnapshot {
        var snapshot = PersonalHealthSnapshot()
        for type in types {
            let samples = try await read(type, start: start, end: end)
            snapshot.samples[type.identifier] = samples
            if let quantity = type as? HKQuantityType,
               quantity.identifier == HKQuantityTypeIdentifier.stepCount.rawValue || quantity.identifier == HKQuantityTypeIdentifier.activeEnergyBurned.rawValue {
                snapshot.totals[quantity.identifier] = try await watchTotals(quantity, samples: samples, start: start, end: end)
            }
        }
        return snapshot
    }
    private func read(_ type: HKSampleType, start: Date, end: Date) async throws -> [HKSample] {
        try await withCheckedThrowingContinuation { continuation in
            let query = HKSampleQuery(sampleType: type,
                predicate: HKQuery.predicateForSamples(withStart: start, end: end),
                limit: HKObjectQueryNoLimit,
                sortDescriptors: [NSSortDescriptor(key: HKSampleSortIdentifierStartDate, ascending: true)]) { _, samples, error in
                    if let error { continuation.resume(throwing: error) }
                    else { continuation.resume(returning: samples ?? []) }
                }
            store.execute(query)
        }
    }
    nonisolated static func source(_ sample: HKSample) -> PersonalSource? {
        if sample.sourceRevision.source.bundleIdentifier.lowercased().contains("oura") { return .ring }
        if sample.sourceRevision.productType?.hasPrefix("Watch") == true || sample.device?.model?.localizedCaseInsensitiveContains("watch") == true { return .watch }
        return nil
    }
    nonisolated static func identity(_ sample: HKSample) -> String {
        [sample.sourceRevision.source.bundleIdentifier, sample.device?.localIdentifier ?? sample.sourceRevision.productType ?? "unknown-device"].joined(separator: "|")
    }
    private func watchTotals(_ type: HKQuantityType, samples: [HKSample], start: Date, end: Date) async throws -> [Date: PersonalValue] {
        // Select one exact Watch source/device for this metric. Other sources never get added.
        let watch = samples.filter { Self.source($0) == .watch }
        let groups = Dictionary(grouping: watch, by: Self.identity)
        var byIdentity: [String: [Date: Double]] = [:]
        for (identity, records) in groups {
            // Exact sample UUID predicate excludes phone/third-party samples even when
            // HealthKit reports the same source bundle for several devices.
            let ids = Set(records.map(\.uuid))
            let predicate = HKQuery.predicateForObjects(with: ids)
            let unit: HKUnit = type.identifier == HKQuantityTypeIdentifier.stepCount.rawValue ? .count() : .kilocalorie()
            let totals: [Date: Double] = try await withCheckedThrowingContinuation { continuation in
                let query = HKStatisticsCollectionQuery(quantityType: type, quantitySamplePredicate: predicate,
                    options: .cumulativeSum, anchorDate: Calendar.current.startOfDay(for: start), intervalComponents: DateComponents(day: 1))
                query.initialResultsHandler = { _, collection, error in
                    if let error { continuation.resume(throwing: error); return }
                    var result: [Date: Double] = [:]
                    collection?.enumerateStatistics(from: start, to: end) { stats, _ in
                        if let sum = stats.sumQuantity() { result[stats.startDate] = sum.doubleValue(for: unit) }
                    }
                    continuation.resume(returning: result)
                }
                store.execute(query)
            }
            byIdentity[identity] = totals
        }
        var result: [Date: PersonalValue] = [:]
        let dates = Set(byIdentity.values.flatMap { $0.keys })
        for day in dates {
            // Stable preference within the source: greatest sample coverage, then identity.
            let selected = groups.keys.filter { byIdentity[$0]?[day] != nil }.sorted { a, b in
                let ac = groups[a]!.filter { Calendar.current.isDate($0.startDate, inSameDayAs: day) }.count
                let bc = groups[b]!.filter { Calendar.current.isDate($0.startDate, inSameDayAs: day) }.count
                return ac == bc ? a < b : ac > bc
            }.first
            if let selected, let value = byIdentity[selected]?[day] {
                result[day] = PersonalValue(value: value, source: .watch, identity: selected)
            }
        }
        return result
    }
}
