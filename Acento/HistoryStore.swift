import Foundation
import SQLite3

/// Dictation history persisted in SQLite. Audio stays as WAV files in the
/// Recordings folder; each row only references its file name.
final class HistoryStore {
    private var db: OpaquePointer?

    /// Pass `nil` for an in-memory database (previews and checks).
    init(url: URL?) throws {
        let path = url?.path ?? ":memory:"
        isPersistent = url != nil
        guard sqlite3_open_v2(path, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK else {
            let message = db.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown error"
            sqlite3_close(db)
            db = nil
            throw SpeechFailure("Could not open the history database: \(message)")
        }
        try execute("PRAGMA journal_mode = WAL")
        try execute("""
            CREATE TABLE IF NOT EXISTS dictations (
                id TEXT PRIMARY KEY NOT NULL,
                position INTEGER NOT NULL,
                created_at REAL,
                time TEXT NOT NULL,
                day TEXT NOT NULL,
                text TEXT NOT NULL,
                raw_text TEXT,
                flagged INTEGER NOT NULL DEFAULT 0,
                audio_file TEXT
            )
            """)
        try execute("CREATE INDEX IF NOT EXISTS dictations_created_at ON dictations(created_at)")
        try execute("""
            CREATE TABLE IF NOT EXISTS dictionary_terms (
                id TEXT PRIMARY KEY NOT NULL,
                position INTEGER NOT NULL,
                spoken TEXT NOT NULL,
                written TEXT NOT NULL,
                mode TEXT NOT NULL
            )
            """)
    }

    let isPersistent: Bool

    deinit { sqlite3_close(db) }

    /// Opens the app's database and imports the legacy UserDefaults history once.
    static func openDefault(defaults: UserDefaults = .standard) -> HistoryStore? {
        let url = Bundle.main.bundleIdentifier == nil ? nil
            : try? RecordingStorage.folder("History").appendingPathComponent("history.sqlite")
        guard let store = try? HistoryStore(url: url) else { return nil }
        if url != nil { migrateLegacyHistory(into: store, defaults: defaults) }
        return store
    }

    /// Imports the JSON history previously kept in UserDefaults, once. The old value is left as a backup.
    static func migrateLegacyHistory(into store: HistoryStore, defaults: UserDefaults) {
        guard !defaults.bool(forKey: migrationKey) else { return }
        if let data = defaults.data(forKey: "history"),
           let legacy = try? JSONDecoder().decode([DictationEntry].self, from: data),
           store.load().isEmpty {
            guard (try? store.replaceAll(legacy)) != nil else { return }
        }
        defaults.set(true, forKey: migrationKey)
    }

    private static let migrationKey = "historyMigratedToSQLite"

    func load() -> [DictationEntry] {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, """
            SELECT id, created_at, time, day, text, raw_text, flagged, audio_file
            FROM dictations ORDER BY position
            """, -1, &statement, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(statement) }
        var entries: [DictationEntry] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let id = UUID(uuidString: column(statement, 0) ?? "") else { continue }
            entries.append(DictationEntry(
                id: id,
                time: column(statement, 2) ?? "",
                text: column(statement, 4) ?? "",
                day: column(statement, 3) ?? "",
                flagged: sqlite3_column_int(statement, 6) != 0,
                audioFile: column(statement, 7),
                createdAt: sqlite3_column_type(statement, 1) == SQLITE_NULL ? nil
                    : Date(timeIntervalSince1970: sqlite3_column_double(statement, 1)),
                rawText: column(statement, 5)
            ))
        }
        return entries
    }

    func replaceAll(_ entries: [DictationEntry]) throws {
        try execute("BEGIN IMMEDIATE")
        do {
            try execute("DELETE FROM dictations")
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(db, """
                INSERT INTO dictations (id, position, created_at, time, day, text, raw_text, flagged, audio_file)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
                """, -1, &statement, nil) == SQLITE_OK else { throw failure() }
            defer { sqlite3_finalize(statement) }
            for (position, entry) in entries.enumerated() {
                sqlite3_reset(statement)
                bind(statement, 1, entry.id.uuidString)
                sqlite3_bind_int64(statement, 2, Int64(position))
                if let createdAt = entry.createdAt {
                    sqlite3_bind_double(statement, 3, createdAt.timeIntervalSince1970)
                } else {
                    sqlite3_bind_null(statement, 3)
                }
                bind(statement, 4, entry.time)
                bind(statement, 5, entry.day)
                bind(statement, 6, entry.text)
                bind(statement, 7, entry.rawText)
                sqlite3_bind_int(statement, 8, entry.flagged ? 1 : 0)
                bind(statement, 9, entry.audioFile)
                guard sqlite3_step(statement) == SQLITE_DONE else { throw failure() }
            }
            try execute("COMMIT")
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }

    // MARK: Dictionary
    // Each word is written on its own, so a stale copy of the list can never overwrite other words.

    func loadTerms() -> [DictionaryTerm] {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT id, spoken, written, mode FROM dictionary_terms ORDER BY position, rowid",
                                 -1, &statement, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(statement) }
        var terms: [DictionaryTerm] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let id = UUID(uuidString: column(statement, 0) ?? "") else { continue }
            terms.append(DictionaryTerm(id: id, spoken: column(statement, 1) ?? "", written: column(statement, 2) ?? "",
                                        mode: DictionaryMode(rawValue: column(statement, 3) ?? "") ?? .direct))
        }
        return terms
    }

    /// Inserts or updates one word. New words go last unless a position is given; edits keep their place.
    func upsertTerm(_ term: DictionaryTerm, position: Int? = nil) throws {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, """
            INSERT INTO dictionary_terms (id, position, spoken, written, mode)
            VALUES (?, COALESCE(?, (SELECT COALESCE(MAX(position), -1) + 1 FROM dictionary_terms)), ?, ?, ?)
            ON CONFLICT(id) DO UPDATE SET spoken = excluded.spoken, written = excluded.written, mode = excluded.mode
            """, -1, &statement, nil) == SQLITE_OK else { throw failure() }
        defer { sqlite3_finalize(statement) }
        bind(statement, 1, term.id.uuidString)
        if let position { sqlite3_bind_int64(statement, 2, Int64(position)) } else { sqlite3_bind_null(statement, 2) }
        bind(statement, 3, term.spoken)
        bind(statement, 4, term.written)
        bind(statement, 5, term.mode.rawValue)
        guard sqlite3_step(statement) == SQLITE_DONE else { throw failure() }
    }

    /// Removes one word and returns its stored position, so undo can put it back in place.
    @discardableResult
    func deleteTerm(_ id: UUID) throws -> Int? {
        var position: Int?
        var query: OpaquePointer?
        if sqlite3_prepare_v2(db, "SELECT position FROM dictionary_terms WHERE id = ?", -1, &query, nil) == SQLITE_OK {
            bind(query, 1, id.uuidString)
            if sqlite3_step(query) == SQLITE_ROW { position = Int(sqlite3_column_int64(query, 0)) }
        }
        sqlite3_finalize(query)
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, "DELETE FROM dictionary_terms WHERE id = ?", -1, &statement, nil) == SQLITE_OK else { throw failure() }
        defer { sqlite3_finalize(statement) }
        bind(statement, 1, id.uuidString)
        guard sqlite3_step(statement) == SQLITE_DONE else { throw failure() }
        return position
    }

    /// First launch with SQLite: imports the UserDefaults dictionary (kept as a backup) or the starter words, once.
    func loadTerms(migratingFrom defaults: UserDefaults, starter: [DictionaryTerm]) -> [DictionaryTerm] {
        let stored = loadTerms()
        guard stored.isEmpty, !(isPersistent && defaults.bool(forKey: Self.termsMigrationKey)) else { return stored }
        let legacy = defaults.data(forKey: "dictionary").flatMap { try? JSONDecoder().decode([DictionaryTerm].self, from: $0) }
        let initial = legacy ?? starter
        do {
            try execute("BEGIN IMMEDIATE")
            for (position, term) in initial.enumerated() { try upsertTerm(term, position: position) }
            try execute("COMMIT")
        } catch {
            try? execute("ROLLBACK")
            return initial
        }
        if isPersistent { defaults.set(true, forKey: Self.termsMigrationKey) }
        return initial
    }

    private static let termsMigrationKey = "dictionaryMigratedToSQLite"

    private func execute(_ sql: String) throws {
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else { throw failure() }
    }

    private func failure() -> SpeechFailure {
        SpeechFailure("History database error: \(String(cString: sqlite3_errmsg(db)))")
    }

    private func column(_ statement: OpaquePointer?, _ index: Int32) -> String? {
        guard let text = sqlite3_column_text(statement, index) else { return nil }
        return String(cString: text)
    }

    private func bind(_ statement: OpaquePointer?, _ index: Int32, _ value: String?) {
        guard let value else {
            sqlite3_bind_null(statement, index)
            return
        }
        sqlite3_bind_text(statement, index, value, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
    }
}
