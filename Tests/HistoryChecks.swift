import Foundation

// Uses temporary databases and UserDefaults suites; real history and recordings are untouched.
enum RecordingStorage {
    nonisolated(unsafe) static var deleted: [String] = []
    static func delete(_ filename: String?) { if let filename { deleted.append(filename) } }
    static func folder(_ name: String) throws -> URL { FileManager.default.temporaryDirectory }
}
struct SpeechFailure: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

@main
struct HistoryChecks {
    static func check(_ condition: Bool, _ message: String) {
        precondition(condition, message)
        print("✓ \(message)")
    }

    static func main() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("history-checks-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("history.sqlite")

        let now = Date()
        let entries = [
            DictationEntry(time: "9:00", text: "Hola", day: "TODAY", flagged: true, audioFile: "\(UUID().uuidString).wav", createdAt: now, rawText: "hola"),
            DictationEntry(time: "8:00", text: "", day: "TODAY", audioFile: "\(UUID().uuidString).wav", createdAt: now.addingTimeInterval(-3600)),
            DictationEntry(time: "7:00", text: "Legacy", day: "TODAY")
        ]
        try HistoryStore(url: url).replaceAll(entries)
        let reloaded = try HistoryStore(url: url).load()
        check(reloaded.map(\.id) == entries.map(\.id), "SQLite keeps dictation order and identity across reopen")
        check(reloaded[0].flagged && reloaded[0].rawText == "hola" && reloaded[0].audioFile == entries[0].audioFile,
              "Flags, raw text and audio file references persist")
        check(reloaded[1].isFailed && reloaded[1].audioFile != nil, "Failed transcriptions keep their audio reference for retry")
        check(reloaded[2].createdAt == nil && abs(reloaded[0].createdAt!.timeIntervalSince(now)) < 0.001, "Dates round-trip, missing dates stay nil")

        let store = try HistoryStore(url: url)
        try store.replaceAll(Array(reloaded.dropFirst()))
        check(store.load().count == 2, "Deletions are persisted")

        let calendar = Calendar(identifier: .gregorian)
        let reference = calendar.date(from: DateComponents(year: 2026, month: 11, day: 10, hour: 9))!
        func day(_ offset: Int, hour: Int = 12) -> Date {
            calendar.date(byAdding: .day, value: offset, to: calendar.date(bySettingHour: hour, minute: 0, second: 0, of: reference)!)!
        }
        let history = [
            DictationEntry(time: "", text: "a", day: "TODAY", createdAt: day(-1, hour: 18)),
            DictationEntry(time: "", text: "b", day: "TODAY", createdAt: day(-1, hour: 9)),
            DictationEntry(time: "", text: "c", day: "TODAY", createdAt: day(-7)),
            DictationEntry(time: "", text: "d", day: "TODAY", createdAt: day(-8)),
            DictationEntry(time: "", text: "e", day: "TODAY", createdAt: day(-400)),
            DictationEntry(time: "", text: "f", day: "TODAY")
        ]
        let sections = DictationDaySection.group(history, now: reference, calendar: calendar)
        check(sections.map(\.id) == ["TODAY", "YESTERDAY", "2026-11-03", "2026-11-02", "2025-10-06", "EARLIER"],
              "History is split per calendar day, newest first, with an always-present Today")
        check(sections[0].entries.isEmpty && sections[1].entries.map(\.text) == ["a", "b"], "Entries of the same day stay together")
        let spanish = Locale(identifier: "es_MX")
        check(sections[2].title(locale: spanish, now: reference, calendar: calendar) == "MARTES, 3 DE NOVIEMBRE",
              "Older days show a localized weekday and date")
        check(sections[4].title(locale: spanish, now: reference, calendar: calendar).contains("2025"), "Days from other years include the year")

        let suite = "history-checks-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(try JSONEncoder().encode(entries), forKey: "history")
        let migrated = try HistoryStore(url: folder.appendingPathComponent("migrated.sqlite"))
        HistoryStore.migrateLegacyHistory(into: migrated, defaults: defaults)
        check(migrated.load().map(\.id) == entries.map(\.id), "Legacy UserDefaults history is imported into SQLite")
        try migrated.replaceAll([])
        HistoryStore.migrateLegacyHistory(into: migrated, defaults: defaults)
        check(migrated.load().isEmpty, "Migration runs only once")

        let legacyTerms = [DictionaryTerm(spoken: "comité", written: "commit", mode: .direct),
                           DictionaryTerm(spoken: "Broly", written: "Broly")]
        defaults.set(try JSONEncoder().encode(legacyTerms), forKey: "dictionary")
        let termsURL = folder.appendingPathComponent("terms.sqlite")
        let firstCopy = try HistoryStore(url: termsURL)
        check(firstCopy.loadTerms(migratingFrom: defaults, starter: []) == legacyTerms
              && defaults.data(forKey: "dictionary") != nil, "The dictionary moves to SQLite and UserDefaults keeps a backup")
        let staleCopy = try HistoryStore(url: termsURL)
        let added = DictionaryTerm(spoken: "Acento", written: "Acento", mode: .direct)
        try firstCopy.upsertTerm(added)
        let brolyPosition = try staleCopy.deleteTerm(legacyTerms[1].id)
        check(try HistoryStore(url: termsURL).loadTerms() == [legacyTerms[0], added],
              "Deleting from a stale copy of the app never drops words added elsewhere")
        try staleCopy.upsertTerm(legacyTerms[1], position: brolyPosition)
        check(firstCopy.loadTerms().map(\.spoken) == ["comité", "Broly", "Acento"], "Undo puts a word back in its place")
        try firstCopy.deleteTerm(added.id)
        try firstCopy.deleteTerm(legacyTerms[0].id)
        try firstCopy.deleteTerm(legacyTerms[1].id)
        check(try HistoryStore(url: termsURL).loadTerms(migratingFrom: defaults, starter: legacyTerms).isEmpty,
              "An emptied dictionary stays empty instead of re-importing old words")

        let model = AppModel(historyStore: try HistoryStore(url: nil))
        model.history = entries
        RecordingStorage.deleted = []
        let removed = model.removeAudio { !$0.isFailed && $0.createdAt != nil }
        check(removed == 1 && RecordingStorage.deleted == [entries[0].audioFile!], "Only matching recordings are deleted")
        check(model.history.map(\.text) == entries.map(\.text) && model.history[0].audioFile == nil && model.history[1].audioFile != nil,
              "Transcripts stay in history after their audio is removed")
    }
}
