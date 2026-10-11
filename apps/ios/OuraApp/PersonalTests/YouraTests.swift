import XCTest
@testable import OuraApp

final class YouraTests: XCTestCase {
    private var calendar: Calendar { var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(identifier: "America/Los_Angeles")!; return c }
    private func date(_ value: String) -> Date { let f = ISO8601DateFormatter(); return f.date(from: value)! }
    private var anchor: Date { calendar.startOfDay(for: date("2026-10-10T12:00:00Z")) }
    private func day(offset: Int, hours: Double = 8, identity: String = "direct-ring:synthetic", source: PersonalSource = .ring) -> PersonalDay {
        let wakeDate = calendar.date(byAdding: .day, value: offset, to: anchor)!
        let end = calendar.date(bySettingHour: 7, minute: 0, second: 0, of: wakeDate)!
        let start = end.addingTimeInterval(-hours * 3600)
        let night = PersonalNight(start: start, end: end, source: source, identity: identity, hours: hours, restorativeHours: nil,
            stages: [.init(start: start, end: end, label: "Core")], heartRate: [], bedStart: start, bedEnd: end)
        return PersonalDay(date: wakeDate, night: night)
    }
    func testUnmentionedHabitsRemainUnknownAndNegationIsRespected() {
        let draft = VoiceJournalDraft.parse("I didn't have coffee. I had wine at 8pm. Not stressed.", date: anchor, calendar: calendar)
        XCTAssertEqual(draft.entries.first { $0.habit == .caffeine }?.answer, .no)
        XCTAssertEqual(draft.entries.first { $0.habit == .alcohol }?.answer, .yes)
        XCTAssertEqual(draft.entries.first { $0.habit == .stress }?.answer, .no)
        XCTAssertEqual(draft.entries.first { $0.habit == .lateMeal }?.answer, .unknown)
        XCTAssertEqual(calendar.component(.hour, from: draft.entries.first { $0.habit == .alcohol }!.time!), 20)
    }
    func testAmbiguousTimesAndCorrectionsRequireReview() {
        let draft = VoiceJournalDraft.parse("Coffee around four. No coffee actually. Maybe a late meal.", date: anchor, calendar: calendar)
        XCTAssertEqual(draft.entries.first { $0.habit == .caffeine }?.answer, .unknown)
        XCTAssertNil(draft.entries.first { $0.habit == .caffeine }?.time)
        XCTAssertTrue(draft.questions.contains { $0.contains("AM or PM") })
        XCTAssertEqual(draft.entries.first { $0.habit == .lateMeal }?.answer, .unknown)
    }
    func testSpokenFollowupCorrectsOnlyMentionedHabitsIncludingUnknown() {
        var draft = VoiceJournalDraft.parse("Coffee. Wine.", date: anchor, calendar: calendar)
        draft = draft.applyingFollowup("No.", habit: .caffeine, calendar: calendar)
        XCTAssertEqual(draft.entries.first { $0.habit == .caffeine }?.answer, .no)
        XCTAssertEqual(draft.entries.first { $0.habit == .alcohol }?.answer, .yes)
        draft = draft.applyingFollowup("Maybe wine", habit: .alcohol, calendar: calendar)
        XCTAssertEqual(draft.entries.first { $0.habit == .alcohol }?.answer, .unknown)
    }
    func testUnknownCheckInsDoNotBecomeUnexposedNights() {
        let days = (-14...0).map { day(offset: $0) }
        let entries = days.prefix(5).map { HabitEntry(nightDate: $0.date, habit: .caffeine, answer: .yes) }
        let result = YouraInsights.build(days: days, entries: entries, now: anchor.addingTimeInterval(86400), calendar: calendar)
        let caffeine = result.patterns.first { $0.id == "caffeine-sleep" }!
        XCTAssertEqual(caffeine.a.count, 5); XCTAssertEqual(caffeine.b.count, 0); XCTAssertFalse(caffeine.supported)
        XCTAssertTrue(result.brief.contains { $0.contains("preceding 14-night median") })
    }
    func testComparisonsRequireFivePerGroupAndExcludeUnlikeSourcesAndArchives() {
        var days = (-9...0).map { day(offset: $0, hours: $0 < -4 ? 7 : 8) }
        let entries = days.enumerated().map { HabitEntry(nightDate: $0.element.date, habit: .caffeine, answer: $0.offset < 5 ? .yes : .no) }
        let result = YouraInsights.build(days: days, entries: entries, now: anchor.addingTimeInterval(86400), calendar: calendar)
        let caffeine = result.patterns.first { $0.id == "caffeine-sleep" }!
        XCTAssertTrue(caffeine.supported); XCTAssertEqual(caffeine.difference!, -1, accuracy: 0.001)
        days[0].night?.identity = "oura-account-export:synthetic"
        days[1].night?.identity = "direct-ring:other"
        days[2].night?.source = .watch
        days[3].night?.hrvMethod = "SDNN"
        let excluded = YouraInsights.build(days: days, entries: entries, now: anchor.addingTimeInterval(86400), calendar: calendar)
        XCTAssertEqual(excluded.patterns.first { $0.id == "caffeine-sleep" }!.a.count, 1)
    }
    func testMissingStagesAndIncompleteCoverageAreExcluded() {
        var d = day(offset: 0); d.night?.stages = []
        XCTAssertFalse(YouraInsights.valid(d.night!))
        d = day(offset: 0); let incompleteEnd = d.night!.start.addingTimeInterval(3600); d.night?.stages[0].end = incompleteEnd
        XCTAssertFalse(YouraInsights.valid(d.night!))
        XCTAssertNil(YouraInsights.build(days: [d], entries: [], calendar: calendar).latestDate)
    }
    func testScheduleAcrossMidnightDoesNotCreateTwentyFourHourDifference() {
        let days = (-9...0).map { day(offset: $0, hours: $0 < -4 ? 7.5 : 6.5) }
        let entries = days.enumerated().map { HabitEntry(nightDate: $0.element.date, habit: .freeDay, answer: $0.offset < 5 ? .yes : .no) }
        let result = YouraInsights.build(days: days, entries: entries, now: anchor.addingTimeInterval(86400), calendar: calendar)
        XCTAssertEqual(result.patterns.first { $0.id == "schedule-onset" }!.difference!, -60, accuracy: 0.001)
    }
    func testDSTUsesRealElapsedDurationAndLocalClock() {
        let start = date("2026-11-01T06:30:00Z"), end = date("2026-11-01T15:00:00Z")
        let n = PersonalNight(start: start, end: end, source: .ring, identity: "direct-ring:synthetic", hours: 8.5, restorativeHours: nil,
            stages: [.init(start: start, end: end, label: "Core")], heartRate: [], bedStart: start, bedEnd: end)
        XCTAssertTrue(YouraInsights.valid(n)); XCTAssertEqual(n.value(.timeInBed), 8.5)
        XCTAssertEqual(calendar.component(.hour, from: end), 7)
    }
    func testSparseHRAndDuplicateSamplesDoNotManufactureWindows() {
        var n = day(offset: 0).night!
        n.heartRate = (0..<50).map { _ in PersonalPoint(time: n.start, value: 60) }
        var result = YouraInsights.heartRate(n)
        XCTAssertNil(result.firstMedian); XCTAssertNil(result.lowestMedian)
        n.heartRate = (0..<96).map { PersonalPoint(time: n.start.addingTimeInterval(Double($0) * 300), value: $0 < 32 ? 65 : 55) }
        result = YouraInsights.heartRate(n)
        XCTAssertEqual(result.firstMedian, 65); XCTAssertEqual(result.lastMedian, 55)
        XCTAssertNotNil(result.lowestWindow); XCTAssertEqual(result.lowestMedian, 55)
    }
    func testNoWorkoutsDoesNotMeanEarlierWorkout() {
        let days = (-9...0).map { day(offset: $0) }
        let result = YouraInsights.build(days: days, entries: [], now: anchor.addingTimeInterval(86400), calendar: calendar)
        XCTAssertTrue(result.patterns.filter { $0.id.hasPrefix("workout-") }.allSatisfy { $0.evidence.isEmpty })
    }
    func testWorkoutUsesActualEndAcrossCalendarDays() {
        var days = (-9...0).map { day(offset: $0) }
        for i in days.indices {
            let onset = days[i].night!.asleepStart!
            days[i].workouts = [.init(id: "synthetic-\(i)", start: onset.addingTimeInterval(i < 5 ? -3600 : -14400), minutes: 30, title: "Synthetic workout", source: .watch)]
        }
        let result = YouraInsights.build(days: days, entries: [], now: anchor.addingTimeInterval(86400), calendar: calendar)
        XCTAssertTrue(result.patterns.first { $0.id == "workout-sleep" }!.supported)
    }
    func testContextContainsNoDeviceIdentityRawRecordsOrUnselectedJournal() {
        let d = day(offset: 0, identity: "direct-ring:PRIVATE-SERIAL")
        let context = YouraInsights.build(days: [d], entries: [.init(nightDate: anchor, habit: .alcohol, answer: .yes)], now: anchor.addingTimeInterval(86400), calendar: calendar).context.preview
        XCTAssertFalse(context.contains("PRIVATE-SERIAL")); XCTAssertFalse(context.contains("Alcohol: Yes"))
    }
    func testHermesURLValidationAndNamedProfile() throws {
        for value in ["http://example.com", "https://user:secret@example.com", "https://example.com?token=bad", "https://example.com/#bad", "bad"] {
            XCTAssertThrowsError(try HermesConfiguration(baseURL: value).endpoint())
        }
        XCTAssertEqual(try HermesConfiguration(baseURL: "https://example.com/p/youra/v1").endpoint().absoluteString, "https://example.com/p/youra/v1/chat/completions")
        XCTAssertEqual(try YouraDailyBriefClient.endpoint(server: "https://example.com/p/youra/v1").absoluteString,
                       "https://example.com/youra-morning-brief/v1/schedule")
        XCTAssertThrowsError(try YouraDailyBriefClient.endpoint(server: "http://example.com/p/youra/v1"))
    }
    func testDailyBriefRequestContainsOnlyCompleteDirectOuraSummary() throws {
        let start = date("2026-10-09T22:00:00Z"), wake = date("2026-10-10T06:00:00Z")
        let night = PersonalNight(start: start, end: wake, source: .ring, identity: "direct-ring:private-serial",
            hours: 7.5, restorativeHours: nil, stages: [.init(start: start, end: wake, label: "Core")],
            heartRate: [], bedStart: start, bedEnd: wake)
        let request = try YouraDailyBriefClient.request(server: "https://example.com/p/youra/v1", token: "test-token", nightDate: anchor, night: night)
        XCTAssertEqual(request.url?.absoluteString, "https://example.com/youra-morning-brief/v1/schedule")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer test-token")
        let body = String(data: request.httpBody!, encoding: .utf8)!
        XCTAssertTrue(body.contains("direct-oura-bluetooth"))
        XCTAssertTrue(body.contains("totalSleepMinutes")); XCTAssertTrue(body.contains("onsetAt"))
        XCTAssertFalse(body.contains("private-serial")); XCTAssertFalse(body.contains("test-token"))
        XCTAssertFalse(body.contains("heartRate")); XCTAssertFalse(body.contains("Apple Health"))
        var watchNight = night; watchNight.source = .watch
        XCTAssertThrowsError(try YouraDailyBriefClient.request(server: "https://example.com", token: "test-token", nightDate: anchor, night: watchNight))
        var exportNight = night; exportNight.identity = "oura-account-export:synthetic"
        XCTAssertThrowsError(try YouraDailyBriefClient.request(server: "https://example.com", token: "test-token", nightDate: anchor, night: exportNight))
    }
    func testHermesRequestContainsOnlyApprovedTextAndSeparateHeaderToken() throws {
        let request = try HermesClient.request(configuration: .init(baseURL: "https://example.com/v1"), token: "synthetic-token", preview: "Approved synthetic text")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer synthetic-token")
        let body = String(data: request.httpBody!, encoding: .utf8)!
        XCTAssertFalse(body.contains("synthetic-token")); XCTAssertFalse(body.contains("ring-auth-key"))
        XCTAssertTrue(body.contains("Approved synthetic text")); XCTAssertTrue(body.contains("\"stream\":false"))
        XCTAssertThrowsError(try HermesClient.request(configuration: .init(baseURL: "https://example.com"), token: "", preview: "Text"))
    }
    func testHermesRejectsHTTPFailuresEmptyAndMalformedReplies() throws {
        let url = URL(string: "https://example.com/v1/chat/completions")!
        func response(_ code: Int) -> HTTPURLResponse { HTTPURLResponse(url: url, statusCode: code, httpVersion: nil, headerFields: nil)! }
        XCTAssertThrowsError(try HermesClient.decode(Data("{}".utf8), response: response(401)))
        XCTAssertThrowsError(try HermesClient.decode(Data("not-json".utf8), response: response(200)))
        XCTAssertThrowsError(try HermesClient.decode(Data("{\"choices\":[]}".utf8), response: response(200)))
        XCTAssertEqual(try HermesClient.decode(Data("{\"choices\":[{\"message\":{\"content\":\"Synthetic reply\"}}]}".utf8), response: response(200)), "Synthetic reply")
    }
    func testJournalRoundTripUsesSeparateStoreAndUnknownIsPreserved() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("youra-test-\(UUID().uuidString)")
        let store = YouraJournalStore(url: directory.appendingPathComponent("entries.json"))
        let initial = try await store.load(); XCTAssertTrue(initial.isEmpty)
        try await store.save([.init(nightDate: anchor, habit: .caffeine, answer: .unknown)])
        let loaded = try await store.load(); XCTAssertEqual(loaded.count, 1); XCTAssertEqual(loaded[0].answer, .unknown)
    }
    func testCancelledHermesRequestCannotStartNetwork() async throws {
        let task = Task { try Task.checkCancellation(); return try await HermesClient().send(configuration: .init(baseURL: "https://example.invalid"), token: "synthetic", preview: "No data") }
        task.cancel()
        do { _ = try await task.value; XCTFail("Cancelled request succeeded") } catch { XCTAssertTrue(error is CancellationError || (error as? URLError)?.code == .cancelled) }
    }
    @MainActor func testSpeechStopDoesNotRequirePermissionsOrStartRecording() {
        let speech = YouraSpeech(); speech.stop(); speech.silence()
        XCTAssertFalse(speech.recording); XCTAssertFalse(speech.preparing)
    }
    func testDeniedMicrophoneAndUnavailableLocalRecognitionFailClosed() {
        XCTAssertFalse(YouraVoiceAccess.canRecord(onDevice: true, speechAuthorized: true, microphoneAllowed: false, available: true))
        XCTAssertFalse(YouraVoiceAccess.canRecord(onDevice: false, speechAuthorized: true, microphoneAllowed: true, available: true))
        XCTAssertFalse(YouraVoiceAccess.canRecord(onDevice: true, speechAuthorized: false, microphoneAllowed: true, available: true))
        XCTAssertFalse(YouraVoiceAccess.canRecord(onDevice: true, speechAuthorized: true, microphoneAllowed: true, available: false))
        XCTAssertTrue(YouraVoiceAccess.canRecord(onDevice: true, speechAuthorized: true, microphoneAllowed: true, available: true))
    }
    func testDuplicateDatesCannotManufactureBaselineOrComparisonCounts() {
        let d = day(offset: 0)
        let repeated = Array(repeating: d, count: 20)
        let result = YouraInsights.build(days: repeated, entries: [.init(nightDate: anchor, habit: .caffeine, answer: .yes)], now: anchor.addingTimeInterval(86400), calendar: calendar)
        XCTAssertEqual(result.patterns.first { $0.id == "caffeine-sleep" }?.evidence.count, 1)
        XCTAssertFalse(result.patterns.contains(where: \.supported))
    }
}
