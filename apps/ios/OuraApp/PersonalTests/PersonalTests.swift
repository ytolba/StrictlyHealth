import XCTest
import SwiftData
@testable import OuraApp

final class PersonalTests: XCTestCase {
    func testCoreClockDiagnosticsAcceptCurrentArraysAndLegacyMaps() throws {
        for payload in ["[]", "{}", "null"] {
            let summary = try JSONDecoder().decode(Summary.self, from: Data("{\"clock\":{\"undated_reasons\":\(payload)}}".utf8))
            XCTAssertEqual(summary.clock?.undated_reasons.count, 0)
        }
        let current = try JSONDecoder().decode(Summary.self, from: Data("""
        {"clock":{"undated_reasons":[{"reason":"missing_anchor","count":2,"recoverable":true,"message":"Synthetic missing anchor","span_h":1.5}]}}
        """.utf8))
        XCTAssertEqual(current.clock?.undated_reasons.first?.count, 2)
        XCTAssertEqual(current.clock?.undated_reasons.first?.recoverable, true)
        let legacy = try JSONDecoder().decode(Summary.self, from: Data("{\"clock\":{\"undated_reasons\":{\"missing_anchor\":3}}}".utf8))
        XCTAssertEqual(legacy.clock?.undated_reasons.first?.count, 3)
    }
    func testRingEpochsAreNotStretchedAndWakeDateOwnsNight() throws {
        let wake = Calendar.current.startOfDay(for: today).addingTimeInterval(6 * 3600)
        let start = Int64(wake.addingTimeInterval(-3600).timeIntervalSince1970)
        let end = Int64(wake.timeIntervalSince1970)
        let data = Data("""
        {"device":{"serial":"synthetic-test"},"nights":[{"start_unix":\(start),"end_unix":\(end),"staging_source":"ring","stages_full":[4,2,3,1],"staging_complete":true,"staging_coverage_pct":100}]}
        """.utf8)
        let summary = try JSONDecoder().decode(Summary.self, from: data)
        let days = PersonalAssembler.build(ring: summary, health: PersonalHealthSnapshot(), preferences: PersonalPreferences(), now: wake)
        let night = try XCTUnwrap(days.last?.night)
        XCTAssertEqual(night.stages.count, 4)
        XCTAssertEqual(night.stages[0].end.timeIntervalSince(night.stages[0].start), 30)
        XCTAssertEqual(night.stages[1].start.timeIntervalSince(night.start), 30)
        XCTAssertNil(night.hours) // Four epochs cannot describe a whole hour.
        XCTAssertEqual(night.sleepSourceTitle, "Oura · Bluetooth")
    }
    @MainActor func testAutomaticSyncScheduling() {
        let now = Date(timeIntervalSince1970: 10000)
        let recent = now.addingTimeInterval(-5)
        XCTAssertTrue(RingSync.shouldSyncAutomatically(now: now, successful: recent, attempted: recent, incomplete: false, paused: false, force: true))
        XCTAssertFalse(RingSync.shouldSyncAutomatically(now: now, successful: nil, attempted: recent, incomplete: true, paused: false, force: false))
        XCTAssertTrue(RingSync.shouldSyncAutomatically(now: now, successful: recent, attempted: recent, incomplete: true, paused: true, force: false))
        XCTAssertFalse(RingSync.shouldSyncAutomatically(now: now, successful: recent, attempted: nil, incomplete: false, paused: false, force: false))
        XCTAssertTrue(RingSync.shouldSyncAutomatically(now: now, successful: now.addingTimeInterval(-181), attempted: nil, incomplete: false, paused: false, force: false))
    }
    func testDefaultSleepModeIsStrictDirectOura() {
        XCTAssertEqual(PersonalPreferences().resolvedSleepInput, .directRing)
        XCTAssertNil(PersonalSleepSelection.choose(direct: nil, health: [.watch: insightNight(), .ring: insightNight()], input: .directRing, preferred: .ring))
    }
    func testPartialDirectSleepIsNotReplacedByCompleteHealthSleep() {
        var direct = insightNight(); direct.hours = nil; direct.stages = []
        var watch = insightNight(); watch.source = .watch; watch.identity = "apple-health:watch"
        let chosen = PersonalSleepSelection.choose(direct: direct, health: [.watch: watch], input: .directRing, preferred: .ring)
        XCTAssertEqual(chosen?.identity, direct.identity)
        XCTAssertNil(chosen?.hours)
    }
    func testSleepFallbackRequiresExplicitAutomaticMode() {
        var watch = insightNight(); watch.source = .watch; watch.identity = "apple-health:watch"
        XCTAssertEqual(PersonalSleepSelection.choose(direct: nil, health: [.watch: watch], input: .automatic, preferred: .ring)?.identity, watch.identity)
        XCTAssertNil(PersonalSleepSelection.choose(direct: insightNight(), health: [:], input: .watch, preferred: .watch))
    }
    func testDirectModeRejectsHealthOrArchiveNightMasqueradingAsDirect() {
        for identity in ["apple-health:oura", "oura-account-export:test"] {
            var invalid = insightNight(); invalid.identity = identity
            XCTAssertNil(PersonalSleepSelection.choose(direct: invalid, health: [:], input: .directRing, preferred: .ring))
            let day = PersonalDay(date: today, night: invalid, directRingNight: invalid)
            XCTAssertNil(day.enforcingSleepInput(.directRing).night)
        }
    }
    func testCachedWatchSleepIsRemovedWithoutRemovingWatchActivity() {
        var watch = insightNight(); watch.source = .watch; watch.identity = "apple-health:watch"
        var day = PersonalDay(date: today, night: watch)
        day.values[PersonalMetric.sleep.rawValue] = PersonalValue(value: 5, source: .watch, identity: watch.identity)
        day.values[PersonalMetric.steps.rawValue] = PersonalValue(value: 1234, source: .watch, identity: watch.identity)
        let live = PersonalLiveSnapshot.build([day], preferences: PersonalPreferences(), goals: PersonalGoals())
        XCTAssertNil(live.days.first?.night)
        XCTAssertNil(live.days.first?.value(.sleep))
        XCTAssertEqual(live.days.first?.value(.steps)?.value, 1234)
        XCTAssertNil(live.scores[today]?.sleep.score)
        XCTAssertEqual(day.night?.identity, watch.identity) // original historical cache is intact
    }
    func testCachedDirectNightIsRestoredInsteadOfWatchFallback() {
        var watch = insightNight(); watch.source = .watch; watch.identity = "apple-health:watch"; watch.hours = 9
        let direct = insightNight()
        let original = PersonalDay(date: today, night: watch, directRingNight: direct)
        let filtered = original.enforcingSleepInput(.directRing)
        XCTAssertEqual(filtered.night?.identity, direct.identity)
        XCTAssertEqual(filtered.value(.sleep)?.value, 5)
        XCTAssertEqual(filtered.value(.deepSleep)?.identity, direct.identity)
        XCTAssertEqual(original.night?.hours, 9)
    }
    func testSleepSourceLabelsDistinguishTransportAndArchives() {
        var night = insightNight()
        XCTAssertEqual(night.sleepSourceTitle, "Oura · Bluetooth")
        night.identity = "apple-health:oura"
        XCTAssertEqual(night.sleepSourceTitle, "Oura · Apple Health")
        night.source = .watch
        XCTAssertEqual(night.sleepSourceTitle, "Apple Watch · Apple Health")
        night.identity = "oura-account-export:test"
        XCTAssertEqual(night.sleepSourceTitle, "Oura export · Historical")
    }
    func testOldPreferenceAndDayJSONRemainCompatible() throws {
        var preferences = PersonalPreferences()
        preferences.priorities[PersonalMetric.sleep.rawValue] = .watch
        let oldPreferences = try JSONEncoder().encode(preferences)
        XCTAssertEqual(try JSONDecoder().decode(PersonalPreferences.self, from: oldPreferences).resolvedSleepInput, .watch)
        preferences.sleepInput = .directRing
        XCTAssertEqual(try JSONDecoder().decode(PersonalPreferences.self, from: JSONEncoder().encode(preferences)).resolvedSleepInput, .directRing)
        let oldDay = PersonalDay(date: today, night: insightNight())
        let decoded = try JSONDecoder().decode(PersonalDay.self, from: JSONEncoder().encode(oldDay))
        XCTAssertNil(decoded.directRingNight)
        XCTAssertEqual(decoded.enforcingSleepInput(.directRing).night?.identity, oldDay.night?.identity)
    }
    private func insightNight() -> PersonalNight {
        let t = today
        let labels = ["Awake", "Core", "Deep", "REM", "Awake", "Core", "Core", "Awake"]
        let stages = labels.enumerated().map { i, label in
            PersonalStage(start: t.addingTimeInterval(Double(i) * 3600), end: t.addingTimeInterval(Double(i + 1) * 3600), label: label)
        }
        return PersonalNight(start: t, end: t.addingTimeInterval(28800), source: .ring, identity: "direct-ring:test", hours: 5, stages: stages, heartRate: [], bedStart: t, bedEnd: t.addingTimeInterval(28800))
    }
    func testSleepEssentialsUseKnownBedWindow() throws {
        var night = insightNight()
        XCTAssertEqual(night.value(.timeInBed), 8)
        XCTAssertEqual(night.value(.efficiency), 62.5)
        XCTAssertEqual(night.value(.latency), 60)
        night.hours = 9
        XCTAssertNil(night.value(.efficiency))
        night.bedStart = nil
        XCTAssertNil(night.value(.timeInBed)); XCTAssertNil(night.value(.latency))
    }
    func testMissingLeadingEpochsAreNotTimeToFallAsleep() {
        var night = insightNight()
        night.stages[0].start = today.addingTimeInterval(120)
        XCTAssertGreaterThan(night.coverage, 0.95)
        XCTAssertNil(night.value(.latency))
        night.stages[0].label = "Unknown"
        XCTAssertEqual(night.asleepStart, today.addingTimeInterval(3600))
        XCTAssertNil(night.value(.latency))
        night.stages[0].label = "Core"; night.stages[0].start = today
        XCTAssertEqual(night.value(.latency), 0)
    }
    func testLongestSleepStretchJoinsStagesButNotAwakeOrGaps() {
        var night = insightNight()
        XCTAssertEqual(night.longestRecordedSleepHours, 3)
        night.stages[2].start = today.addingTimeInterval(7500)
        XCTAssertEqual(night.longestRecordedSleepHours, 2)
        night.stages = []
        XCTAssertNil(night.longestRecordedSleepHours)
    }
    func testSleepMidpointNeedsCoveredTimeline() {
        var night = insightNight()
        XCTAssertEqual(night.sleepWindowMidpoint, today.addingTimeInterval(14400))
        night.stages.remove(at: 3)
        XCTAssertNil(night.sleepWindowMidpoint)
    }
    func testFahrenheitDisplayPreservesRawCelsiusAndConvertsDifferences() {
        let raw = PersonalValue(value: 37, source: .ring, identity: "test")
        XCTAssertEqual(PersonalDisplay.number(raw.value, metric: .skinTemperature), 98.6, accuracy: 0.00001)
        XCTAssertEqual(raw.value, 37)
        XCTAssertEqual(PersonalDisplay.number(0, metric: .skinTemperature), 32)
        XCTAssertEqual(PersonalDisplay.number(-1, metric: .temperatureDeviation), -1.8)
        XCTAssertEqual(PersonalDisplay.unit(.skinTemperature), "°F")
        XCTAssertTrue(PersonalDisplay.value(0.3, metric: .temperatureDeviation).hasSuffix("°F"))
        XCTAssertEqual(PersonalDisplay.value(.nan, metric: .skinTemperature), "—")
    }
    func testSleepRhythmHandlesMidnightAndRequiresComparableNights() throws {
        var cal = Calendar(identifier: .gregorian); cal.timeZone = TimeZone(secondsFromGMT: 0)!
        let end = cal.startOfDay(for: today)
        let offsets = [-10.0, 0, 10]
        var days = offsets.enumerated().map { i, minutes -> PersonalDay in
            let date = cal.date(byAdding: .day, value: i - 2, to: end)!
            let onset = date.addingTimeInterval(minutes * 60), wake = onset.addingTimeInterval(8 * 3600)
            let night = PersonalNight(start: onset, end: wake, source: .ring, identity: "direct-ring:test", hours: 8,
                stages: [PersonalStage(start: onset, end: wake, label: "Core")], heartRate: [], bedStart: onset, bedEnd: wake)
            return PersonalDay(date: date, night: night)
        }
        let chosen = try XCTUnwrap(days.last?.night)
        let result = try XCTUnwrap(PersonalSleepRhythm.calculate(days: days, endingOn: end, night: chosen, goal: 8, calendar: cal))
        XCTAssertEqual(result.bedtimeVariationMinutes, 10, accuracy: 0.001)
        XCTAssertEqual(result.medianSleepHours, 8); XCTAssertEqual(result.goalNights, 3)
        XCTAssertNil(PersonalSleepRhythm.calculate(days: Array(days.prefix(2)), endingOn: end, night: chosen, goal: 8, calendar: cal))
        days[0].night?.identity = "another-ring"
        XCTAssertNil(PersonalSleepRhythm.calculate(days: days, endingOn: end, night: chosen, goal: 8, calendar: cal))
        days[0].night?.identity = chosen.identity; days[0].night?.source = .watch
        XCTAssertNil(PersonalSleepRhythm.calculate(days: days, endingOn: end, night: chosen, goal: 8, calendar: cal))
    }
    func testSleepStoryUsesRecordedDurationAndEditableGoal() {
        let night = PersonalNight(start: today.addingTimeInterval(-8 * 3600), end: today, source: .watch, identity: "watch", hours: 6.5, stages: [], heartRate: [])
        XCTAssertEqual(PersonalDisplay.sleepStory(night, goal: 8), "1 h 30 min below your sleep goal")
        XCTAssertEqual(PersonalDisplay.sleepStory(night, goal: 6.5), "Within 10 minutes of your sleep goal")
        XCTAssertEqual(PersonalDisplay.sleepStory(nil, goal: 8), "Sleep duration unavailable")
        XCTAssertEqual(PersonalDisplay.value(nil, metric: .deepSleep), "—")
    }
    func testSleepChartStageLevelsAreExplicitAndUnknownIsNotInvented() {
        XCTAssertEqual(PersonalStageChart.level("Deep"), 0)
        XCTAssertEqual(PersonalStageChart.level("Core"), 1)
        XCTAssertEqual(PersonalStageChart.level("REM"), 2)
        XCTAssertEqual(PersonalStageChart.level("Awake"), 3)
        XCTAssertEqual(PersonalStageChart.level("Asleep"), 4)
        XCTAssertNil(PersonalStageChart.level("Unknown"))
    }
    func testCondensedSourceLabelsStillIdentifyMethodsAndEstimates() {
        let estimate = PersonalValue(value: 100, source: .ring, identity: "direct-ring|test", method: "Activity-intensity estimate")
        XCTAssertTrue(PersonalDisplay.source(estimate, metric: .steps).contains("Estimated"))
        XCTAssertTrue(PersonalDisplay.source(PersonalValue(value: 50, source: .watch, identity: "watch", method: "SDNN"), metric: .hrv).contains("SDNN"))
    }
    func testOvernightPlotSegmentsOriginalGapsAndDoesNotInspectEmptyIntervals() {
        let points = (0..<10_000).map { PersonalPoint(time: today.addingTimeInterval(Double($0)), value: 60) }
            + [PersonalPoint(time: today.addingTimeInterval(20_000), value: 55)]
        let prepared = PersonalNightCharts.plotPoints(points)
        XCTAssertLessThanOrEqual(prepared.count, 360)
        XCTAssertEqual(Set(prepared.map(\.segment)), [0, 1])
        XCTAssertNil(PersonalNightCharts.inspectedPoint(today.addingTimeInterval(15_000), points: prepared))
        XCTAssertEqual(PersonalNightCharts.inspectedPoint(today.addingTimeInterval(20_000), points: prepared)?.value, 55)
    }
    func testWeekWindowContainsSevenCalendarDaysRegardlessOfMeasurements() {
        let range = PersonalWeekChart.range(endingOn: today)
        XCTAssertEqual(calendar.dateComponents([.day], from: range.lowerBound, to: range.upperBound).day, 7)
        XCTAssertEqual(range.lowerBound, calendar.date(byAdding: .day, value: -6, to: today))
        XCTAssertEqual(range.upperBound, calendar.date(byAdding: .day, value: 1, to: today))
    }
    func testLiveDashboardDoesNotDependOnImportedScoresOrSamples() {
        var day = sample(0)
        day.values[PersonalMetric.steps.rawValue] = PersonalValue(value: 8_000, source: .watch, identity: "watch")
        let before = PersonalLiveScoring.activity(day, goals: PersonalGoals()).score
        day.values[PersonalMetric.activityScore.rawValue] = PersonalValue(value: 1, source: .ring, identity: "oura-account-export")
        day.values[PersonalMetric.sleep.rawValue] = PersonalValue(value: 8, source: .ring, identity: "oura-account-export")
        XCTAssertEqual(PersonalLiveScoring.activity(day, goals: PersonalGoals()).score, before)
        XCTAssertNil(day.liveOnly.value(.sleep))
        XCTAssertNil(day.liveOnly.value(.activityScore))
        var archiveOnly = PersonalDay(date: today)
        archiveOnly.values = [PersonalMetric.sleepScore.rawValue: PersonalValue(value: 99, source: .ring, identity: "oura-account-export")]
        XCTAssertTrue(PersonalLiveSnapshot.build([archiveOnly], preferences: PersonalPreferences(), goals: PersonalGoals()).days.isEmpty)
        XCTAssertNil(PersonalLiveScoring.sleep(archiveOnly, goals: PersonalGoals()).score)
    }
    func testSleepGoalScoreAndMissingCoverage() {
        var day = PersonalDay(date: today)
        let end = today, start = end.addingTimeInterval(-8 * 3600)
        day.night = PersonalNight(start: start, end: end, source: .watch, identity: "watch", hours: 8, stages: [PersonalStage(start: start, end: end, label: "Core")], heartRate: [], bedStart: start, bedEnd: end)
        XCTAssertEqual(PersonalLiveScoring.sleep(day, goals: PersonalGoals()).score, 100)
        var goals = PersonalGoals(); goals.sleepHours = 10
        XCTAssertEqual(PersonalLiveScoring.sleep(day, goals: goals).score, 87)
        day.night?.hours = nil
        XCTAssertNil(PersonalLiveScoring.sleep(day, goals: goals).score)
        day.night?.hours = 8; day.night?.bedStart = nil
        XCTAssertNil(PersonalLiveScoring.sleep(day, goals: goals).score)
    }
    func testActivityScoreIsEditableAndRingEstimatesAreLabeled() {
        var day = PersonalDay(date: today)
        day.values[PersonalMetric.steps.rawValue] = PersonalValue(value: 4_000, source: .ring, identity: "direct-ring|test", method: "Activity-intensity estimate")
        let result = PersonalLiveScoring.activity(day, goals: PersonalGoals())
        XCTAssertEqual(result.score, 50)
        XCTAssertTrue(result.estimated)
        XCTAssertEqual(result.coverage, 0.7, accuracy: 0.001)
        var goals = PersonalGoals(); goals.steps = 4_000
        XCTAssertEqual(PersonalLiveScoring.activity(day, goals: goals).score, 100)
        day.values = [PersonalMetric.energy.rawValue: PersonalValue(value: 400, source: .watch, identity: "watch")]
        XCTAssertNil(PersonalLiveScoring.activity(day, goals: goals).score)
        day.values = [PersonalMetric.steps.rawValue: PersonalValue(value: 0, source: .watch, identity: "watch")]
        XCTAssertEqual(PersonalLiveScoring.activity(day, goals: goals).score, 0)
    }
    func testDisplayHeartRateIsBoundedAndRetainsExtremesAndOriginals() {
        var points = (0..<10_000).map { PersonalPoint(time: today.addingTimeInterval(Double($0)), value: 60) }
        points[4321].value = 120; points[6789].value = 40
        let bounded = PersonalNightCharts.boundedHeartRate(points)
        XCTAssertLessThanOrEqual(bounded.count, 360)
        XCTAssertTrue(bounded.contains { $0.value == 120 })
        XCTAssertTrue(bounded.contains { $0.value == 40 })
        XCTAssertEqual(bounded.first?.time, points.first?.time)
        XCTAssertEqual(bounded.last?.time, points.last?.time)
        XCTAssertEqual(points.count, 10_000)
    }
    func testArchiveBackfillDoesNotReplacePartialLiveNight() throws {
        var day = PersonalDay(date: today)
        day.night = PersonalNight(start: today.addingTimeInterval(-8 * 3600), end: today, source: .ring, identity: "direct-ring|test", stages: [], heartRate: [PersonalPoint(time: today, value: 55)])
        let row = PersonalArchiveRecord(table: "sleep", day: PersonalAssembler.dayKey(today), fields: ["bedtime_start": ISO8601DateFormatter().string(from: today.addingTimeInterval(-8 * 3600)), "bedtime_end": ISO8601DateFormatter().string(from: today), "total_sleep_duration": "28000"])
        let merged = try XCTUnwrap(PersonalArchive.merge([day], records: [row]).first)
        XCTAssertTrue(merged.night?.identity.hasPrefix("oura-account-export") == true)
        let decoded = try JSONDecoder().decode(PersonalDay.self, from: JSONEncoder().encode(merged))
        XCTAssertEqual(decoded.liveOnly.night?.identity, "direct-ring|test")
        XCTAssertEqual(decoded.liveOnly.night?.heartRate.first?.value, 55)
        XCTAssertNil(PersonalLiveScoring.sleep(decoded, goals: PersonalGoals()).score)
    }
    func testSleepContributorsReadNestedAndFlattenedExportsWithoutInventingScores() {
        let nested = PersonalArchiveRecord(table: "dailysleep", day: "2026-10-08", fields: ["contributors": "{\"deep_sleep\":85,\"restfulness\":null,\"timing\":150}"])
        XCTAssertEqual(SleepReportFields.contributor("deep_sleep", records: [nested]), 85)
        XCTAssertNil(SleepReportFields.contributor("restfulness", records: [nested]))
        XCTAssertNil(SleepReportFields.contributor("timing", records: [nested]))
        let flat = PersonalArchiveRecord(table: "dailysleep", day: "2026-10-08", fields: ["contributors.total_sleep": "90", "contributors_latency": "0"])
        XCTAssertEqual(SleepReportFields.contributor("total_sleep", records: [flat]), 90)
        XCTAssertEqual(SleepReportFields.contributor("latency", records: [flat]), 0)
        XCTAssertNil(SleepReportFields.contributor("efficiency", records: [flat]))
        XCTAssertEqual(SleepReportFields.contributors.count, 7)
    }
    func testSleepReportRetainsAllFieldsAndAdditionalSessions() {
        var day = sample(0)
        day.archiveRecords = [PersonalArchiveRecord(table: "sleep", day: "2026-10-08", fields: ["id": "nap", "unknown_future_metric": "42"]), PersonalArchiveRecord(table: "dailyactivity", day: "2026-10-08", fields: [:]), PersonalArchiveRecord(table: "sleepmodel", day: "2026-10-08", fields: [:]), PersonalArchiveRecord(table: "sleepsession", day: "2026-10-08", fields: [:])]
        let records = SleepReportFields.sleepRecords(day)
        XCTAssertEqual(records.count, 3)
        XCTAssertEqual(records.first?.fields["unknown_future_metric"], "42")
    }
    func testCacheDoesNotRewriteUnchangedDays() async throws {
        let container = try ModelContainer(for: PersonalCachedDay.self, configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let worker = await Task.detached { PersonalCacheWorker(modelContainer: container) }.value
        let day = sample(0)
        let inserted = try await worker.persist([day])
        XCTAssertTrue(inserted)
        let first = try await worker.load()
        let unchanged = try await worker.persist([day])
        XCTAssertFalse(unchanged)
        let second = try await worker.load()
        XCTAssertEqual(first.refreshedAt, second.refreshedAt)
        XCTAssertEqual(second.days.first?.value(.hrv), day.value(.hrv))
        var changed = day
        changed.values[PersonalMetric.steps.rawValue] = PersonalValue(value: 200, source: .ring, identity: "ring-1")
        let updated = try await worker.persist([changed])
        XCTAssertTrue(updated)
        let saved = try await worker.load()
        XCTAssertEqual(saved.days.first?.value(.steps)?.value, 200)
    }
    func testChartCompactionPreservesStageBoundariesAndGaps() {
        let t = Date(timeIntervalSince1970: 0)
        let stages = [
            PersonalStage(start: t, end: t.addingTimeInterval(60), label: "Deep"),
            PersonalStage(start: t.addingTimeInterval(60), end: t.addingTimeInterval(120), label: "Deep"),
            PersonalStage(start: t.addingTimeInterval(120), end: t.addingTimeInterval(180), label: "Awake"),
            PersonalStage(start: t.addingTimeInterval(240), end: t.addingTimeInterval(300), label: "Awake")
        ]
        let night = PersonalNight(start: t, end: t.addingTimeInterval(300), source: .ring, identity: "ring-1", stages: stages, heartRate: [])
        XCTAssertEqual(night.chartStages.count, 3)
        XCTAssertEqual(night.chartStages[0].end, t.addingTimeInterval(120))
        XCTAssertEqual(night.stages.count, 4)
    }
    func testScoreBandsHaveStableBoundaries() {
        XCTAssertEqual(ScoreBand.forScore(85), .high)
        XCTAssertEqual(ScoreBand.forScore(84), .moderate)
        XCTAssertEqual(ScoreBand.forScore(70), .moderate)
        XCTAssertEqual(ScoreBand.forScore(69), .low)
    }
    func testOverviewSelectionAndSourceLens() {
        XCTAssertEqual(DashboardSelection.decode("hrv,unknown,steps,hrv"), [.hrv, .steps])
        XCTAssertEqual(DashboardSelection.decode(""), [])
        XCTAssertTrue(DashboardLens.all.includes(.ring))
        XCTAssertFalse(DashboardLens.watch.includes(.ring))
        XCTAssertTrue(DashboardLens.watch.includes(.watch))
    }
    func testSyntheticFixtureHasFullCoverageAndSeparateSources() {
        let days = DashboardDemo.days()
        XCTAssertEqual(days.count, 36)
        XCTAssertEqual(days.last?.night?.coverage ?? 0, 1, accuracy: 0.001)
        XCTAssertEqual(days.last?.value(.hrv)?.method, "RMSSD")
        XCTAssertEqual(days.last?.value(.steps)?.source, .watch)
        XCTAssertEqual(days.last?.night?.awakeningSpans.count, 1)
    }
    func testLegacyAndUnknownRingPairingAreGated() {
        XCTAssertFalse(RingGeneration.gen1.permitsDirectSync)
        XCTAssertFalse(RingGeneration.gen2.permitsPairing)
        XCTAssertFalse(RingGeneration.unknown.permitsPairing)
        XCTAssertTrue(RingGeneration.gen3.permitsPairing)
        XCTAssertTrue(RingGeneration.ring4.permitsDirectSync)
        XCTAssertTrue(RingGeneration.ring5.permitsDirectSync)
    }
    private let calendar = Calendar.current
    private var today: Date { calendar.startOfDay(for: Date()) }
    private func sample(_ offset: Int, method: String = "RMSSD", source: String = "ring-1", value: Double = 50) -> PersonalDay {
        var day = PersonalDay(date: calendar.date(byAdding: .day, value: offset, to: today)!)
        day.values[PersonalMetric.hrv.rawValue] = PersonalValue(value: value, source: .ring, identity: source, method: method)
        return day
    }
    private var hrvOnly: PersonalPreferences {
        var p = PersonalPreferences(); p.hrvWeight = 1; p.rhrWeight = 0; p.sleepWeight = 0; p.stagesWeight = 0
        return p
    }
    func testBaselineExcludesTodayAndOutsideThirtyDays() {
        let history = (-30..<0).map { sample($0) } + [sample(-31, value: 1), sample(0, value: 1000)]
        XCTAssertEqual(PersonalRecovery.calculate(day: sample(0), history: history, preferences: hrvOnly).score, 80)
    }
    func testHrvMethodsAndDevicesNeverShareBaselines() {
        let history = (-30..<0).map { sample($0, method: "SDNN") }
        XCTAssertNil(PersonalRecovery.calculate(day: sample(0), history: history, preferences: hrvOnly).score)
        let otherRing = (-30..<0).map { sample($0, source: "ring-2") }
        XCTAssertNil(PersonalRecovery.calculate(day: sample(0), history: otherRing, preferences: hrvOnly).score)
    }
    func testMinimumHistoryAndMissingValues() {
        XCTAssertNil(PersonalRecovery.calculate(day: sample(0), history: (-13..<0).map { sample($0) }, preferences: hrvOnly).score)
        XCTAssertEqual(PersonalRecovery.calculate(day: sample(0), history: (-14..<0).map { sample($0) }, preferences: hrvOnly).score, 80)
        XCTAssertNil(PersonalRecovery.calculate(day: PersonalDay(date: today), history: [], preferences: hrvOnly).score)
    }
    func testScoreBoundsAndZeroWeights() {
        let history = (-30..<0).map { sample($0) }
        XCTAssertEqual(PersonalRecovery.calculate(day: sample(0, value: 1000), history: history, preferences: hrvOnly).score, 100)
        XCTAssertNil(PersonalRecovery.calculate(day: sample(0, value: .nan), history: history, preferences: hrvOnly).score)
        var p = hrvOnly; p.hrvWeight = 0
        XCTAssertNil(PersonalRecovery.calculate(day: sample(0), history: history, preferences: p).score)
    }
    func testOverlappingSleepIntervalsAreNotDoubleCounted() {
        let start = today
        let hours = PersonalAssembler.unionHours([
            (start, start.addingTimeInterval(7200)),
            (start.addingTimeInterval(3600), start.addingTimeInterval(10800))
        ])
        XCTAssertEqual(hours, 3, accuracy: 0.001)
    }
    func testIncompleteRingStagingDoesNotBecomeSleepDuration() {
        var n = NightRow(); n.start_unix = Int64(today.timeIntervalSince1970 - 28800)
        n.end_unix = Int64(today.timeIntervalSince1970); n.wake_ymd = PersonalAssembler.dayKey(today)
        n.in_bed_h = 8; n.staging_complete = false
        var s = Summary(nights: [n]); s.device = Device(serial: "test-ring")
        let days = PersonalAssembler.build(ring: s, health: PersonalHealthSnapshot(), preferences: PersonalPreferences())
        XCTAssertNil(days.last?.value(.sleep))
        XCTAssertNotNil(days.last?.night)
    }
    func testAwakeningsMergeEpochsAndExcludeBeforeAndAfterSleep() {
        let t = today
        let labels = ["Awake", "Core", "Awake", "Awake", "Deep", "REM", "Awake", "Core", "Awake"]
        let stages = labels.enumerated().map { i, label in PersonalStage(start: t.addingTimeInterval(Double(i) * 300), end: t.addingTimeInterval(Double(i + 1) * 300), label: label) }
        let night = PersonalNight(start: t, end: t.addingTimeInterval(2700), source: .ring, identity: "test", hours: 4.0 / 12, restorativeHours: 2.0 / 12, stages: stages, heartRate: [], bedStart: t, bedEnd: t.addingTimeInterval(2700))
        XCTAssertEqual(night.value(.awakenings), 2)
        XCTAssertEqual(night.asleepStart, t.addingTimeInterval(300))
        XCTAssertEqual(night.asleepEnd, t.addingTimeInterval(2400))
        XCTAssertEqual(night.value(.latency), 5)
        XCTAssertEqual(night.awakeningSpans.first?.end.timeIntervalSince(night.awakeningSpans.first!.start), 600)
    }
    func testMissingStageDataIsNotZeroDeepSleepOrZeroAwakenings() {
        let night = PersonalNight(start: today, end: today.addingTimeInterval(3600), source: .ring, identity: "test", hours: nil, restorativeHours: nil, stages: [], heartRate: [])
        XCTAssertNil(night.value(.deepSleep)); XCTAssertNil(night.value(.awakenings)); XCTAssertNil(night.value(.latency))
    }
    func testUnspecifiedAsleepIsNotZeroDeepSleep() {
        let night = PersonalNight(start: today, end: today.addingTimeInterval(3600), source: .watch, identity: "test", hours: 1, restorativeHours: nil,
            stages: [PersonalStage(start: today, end: today.addingTimeInterval(3600), label: "Asleep")], heartRate: [])
        XCTAssertNil(night.value(.deepSleep)); XCTAssertNil(night.value(.remSleep))
        XCTAssertEqual(night.value(.sleep), 1)
    }
    func testQuotedCSVAndImportedOfficialScore() throws {
        let raw = "id;day;score;contributors\r\nabc;2025-01-01;87;\"{\"\"deep_sleep\"\":91}\"\r\n"
        let parsed = try PersonalArchive.parse(Data(raw.utf8), table: "dailysleep")
        XCTAssertEqual(parsed.records.count, 1)
        XCTAssertEqual(try XCTUnwrap(parsed.records.first).fields["contributors"], "{\"deep_sleep\":91}")
        let days = PersonalArchive.merge([], records: parsed.records)
        XCTAssertEqual(try XCTUnwrap(days.first).value(.sleepScore)?.value, 87)
        XCTAssertNil(days.first?.value(.sleep))
    }
    func testImportPreservesLiveDataAndDoesNotMultiplyHistory() throws {
        let key = PersonalAssembler.dayKey(today)
        let parsed = try PersonalArchive.parse(Data("day;steps;score\n\(key);200;80\n".utf8), table: "dailyactivity")
        var live = PersonalDay(date: today)
        live.values[PersonalMetric.steps.rawValue] = PersonalValue(value: 100, source: .watch, identity: "watch")
        let merged = PersonalArchive.merge([live], records: parsed.records)
        XCTAssertEqual(merged[0].value(.steps)?.value, 100)
        XCTAssertEqual(merged[0].value(.activityScore)?.value, 80)
        XCTAssertEqual(PersonalArchive.merge(merged, records: parsed.records).count, 1)
    }
    func testMalformedCSVRejectsInsteadOfShiftingHealthValues() throws {
        XCTAssertThrowsError(try PersonalArchive.parse(Data("day;score\n2025-01-01;80;999\n".utf8), table: "dailysleep"))
        XCTAssertThrowsError(try PersonalArchive.csv("day,score\n\"unclosed,80", delimiter: ","))
        XCTAssertNil(PersonalArchive.date("2025-02-30"))
    }
    func testExportEpochSpacingNotStretchedAcrossMissingTime() throws {
        let raw = "day;bedtime_start;bedtime_end;total_sleep_duration;sleep_phase_30_sec;deep_sleep_duration;latency\n2025-01-01;2025-01-01T00:00:00+00:00;2025-01-01T01:00:00+00:00;60;411;60;30\n"
        let parsed = try PersonalArchive.parse(Data(raw.utf8), table: "sleepmodel")
        let night = try XCTUnwrap(PersonalArchive.night(parsed.records[0]))
        XCTAssertEqual(night.stages.count, 3)
        XCTAssertEqual(night.stages[0].end.timeIntervalSince(night.stages[0].start), 30)
        XCTAssertLessThan(night.coverage, 0.95)
        XCTAssertNil(night.value(.awakenings))
        XCTAssertEqual(night.value(.deepSleep)!, 60.0 / 3600, accuracy: 0.0001)
    }
}
