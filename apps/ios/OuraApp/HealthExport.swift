import Foundation

// This personal fork only reads HealthKit. Keep the legacy call sites harmless.
final class HealthExport {
    static let shared = HealthExport()
    private init() {}
    func push(_ summary: Summary, force: Bool = false) {}
}
