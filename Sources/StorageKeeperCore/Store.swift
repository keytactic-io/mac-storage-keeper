import Foundation
import SQLite3

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

public enum StoreError: Error, CustomStringConvertible {
    case sqlite(String)
    public var description: String {
        switch self { case .sqlite(let m): return "SQLite: \(m)" }
    }
}

public struct Snapshot: Sendable, Identifiable, Hashable {
    public var id: Int64
    public var root: String
    public var startedAt: Date
    public var finishedAt: Date
    public var totalBytes: Int64
    public var fileCount: Int64
    public var unreadable: Int64
    public var diskTotal: Int64
    public var diskAvailable: Int64
}

public struct ActivityRow: Sendable, Hashable {
    public var time: Date
    public var bucket: String
    public var owner: String
    public var category: Category
    public var bytes: Int64
    public var samplePath: String
}

/// SQLite store shared by the CLI and the menu bar app.
/// Location: ~/Library/Application Support/StorageKeeper/storage.sqlite
public final class Store: @unchecked Sendable {
    private var db: OpaquePointer?
    private let lock = NSRecursiveLock()

    public init(url: URL = Paths.databaseURL) throws {
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(url.path, &db, flags, nil) == SQLITE_OK else {
            throw StoreError.sqlite(String(cString: sqlite3_errmsg(db)))
        }
        sqlite3_busy_timeout(db, 10_000)
        try exec("PRAGMA journal_mode=WAL;")
        try exec("PRAGMA foreign_keys=ON;")
        try exec("""
        CREATE TABLE IF NOT EXISTS snapshots(
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            root TEXT NOT NULL,
            started_at REAL NOT NULL,
            finished_at REAL NOT NULL,
            total_bytes INTEGER NOT NULL,
            file_count INTEGER NOT NULL,
            unreadable INTEGER NOT NULL,
            disk_total INTEGER NOT NULL,
            disk_available INTEGER NOT NULL
        );
        CREATE TABLE IF NOT EXISTS dir_sizes(
            snapshot_id INTEGER NOT NULL REFERENCES snapshots(id) ON DELETE CASCADE,
            path TEXT NOT NULL,
            bytes INTEGER NOT NULL,
            files INTEGER NOT NULL,
            PRIMARY KEY(snapshot_id, path)
        ) WITHOUT ROWID;
        CREATE TABLE IF NOT EXISTS large_files(
            snapshot_id INTEGER NOT NULL REFERENCES snapshots(id) ON DELETE CASCADE,
            path TEXT NOT NULL,
            bytes INTEGER NOT NULL,
            modified REAL NOT NULL
        );
        CREATE INDEX IF NOT EXISTS large_files_snap ON large_files(snapshot_id);
        CREATE TABLE IF NOT EXISTS activity(
            ts REAL NOT NULL,
            bucket TEXT NOT NULL,
            owner TEXT NOT NULL,
            category TEXT NOT NULL,
            bytes INTEGER NOT NULL,
            sample_path TEXT NOT NULL
        );
        CREATE INDEX IF NOT EXISTS activity_ts ON activity(ts);
        """)
    }

    deinit { sqlite3_close_v2(db) }

    // MARK: - Low-level helpers

    private func exec(_ sql: String) throws {
        var err: UnsafeMutablePointer<CChar>?
        if sqlite3_exec(db, sql, nil, nil, &err) != SQLITE_OK {
            let msg = err.map { String(cString: $0) } ?? "unknown error"
            sqlite3_free(err)
            throw StoreError.sqlite(msg)
        }
    }

    private func prepare(_ sql: String) throws -> OpaquePointer? {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw StoreError.sqlite(String(cString: sqlite3_errmsg(db)))
        }
        return stmt
    }

    private func bind(_ stmt: OpaquePointer?, _ idx: Int32, _ value: Any) {
        switch value {
        case let v as Int64: sqlite3_bind_int64(stmt, idx, v)
        case let v as Int: sqlite3_bind_int64(stmt, idx, Int64(v))
        case let v as Double: sqlite3_bind_double(stmt, idx, v)
        case let v as String: sqlite3_bind_text(stmt, idx, v, -1, SQLITE_TRANSIENT)
        default: sqlite3_bind_null(stmt, idx)
        }
    }

    private func query<T>(_ sql: String, _ args: [Any] = [], row: (OpaquePointer?) -> T) throws -> [T] {
        lock.lock(); defer { lock.unlock() }
        let stmt = try prepare(sql)
        defer { sqlite3_finalize(stmt) }
        for (i, a) in args.enumerated() { bind(stmt, Int32(i + 1), a) }
        var out: [T] = []
        while true {
            let rc = sqlite3_step(stmt)
            if rc == SQLITE_ROW { out.append(row(stmt)) }
            else if rc == SQLITE_DONE { break }
            else { throw StoreError.sqlite(String(cString: sqlite3_errmsg(db))) }
        }
        return out
    }

    private func run(_ sql: String, _ args: [Any] = []) throws {
        _ = try query(sql, args) { _ in () }
    }

    private static func text(_ stmt: OpaquePointer?, _ col: Int32) -> String {
        sqlite3_column_text(stmt, col).map { String(cString: $0) } ?? ""
    }

    private static func snapshot(_ s: OpaquePointer?) -> Snapshot {
        Snapshot(id: sqlite3_column_int64(s, 0), root: text(s, 1),
                 startedAt: Date(timeIntervalSince1970: sqlite3_column_double(s, 2)),
                 finishedAt: Date(timeIntervalSince1970: sqlite3_column_double(s, 3)),
                 totalBytes: sqlite3_column_int64(s, 4), fileCount: sqlite3_column_int64(s, 5),
                 unreadable: sqlite3_column_int64(s, 6), diskTotal: sqlite3_column_int64(s, 7),
                 diskAvailable: sqlite3_column_int64(s, 8))
    }

    private static let snapshotColumns = "id, root, started_at, finished_at, total_bytes, file_count, unreadable, disk_total, disk_available"

    // MARK: - Snapshots

    @discardableResult
    public func save(_ r: ScanResult, disk: DiskInfo?) throws -> Int64 {
        lock.lock(); defer { lock.unlock() }
        try exec("BEGIN IMMEDIATE;")
        do {
            try run("INSERT INTO snapshots(root, started_at, finished_at, total_bytes, file_count, unreadable, disk_total, disk_available) VALUES(?,?,?,?,?,?,?,?)",
                    [r.root, r.startedAt.timeIntervalSince1970, r.finishedAt.timeIntervalSince1970,
                     r.totalBytes, r.fileCount, r.unreadable, disk?.total ?? 0, disk?.available ?? 0])
            let id = sqlite3_last_insert_rowid(db)

            let dirStmt = try prepare("INSERT OR REPLACE INTO dir_sizes(snapshot_id, path, bytes, files) VALUES(?,?,?,?)")
            defer { sqlite3_finalize(dirStmt) }
            for d in r.dirs {
                sqlite3_reset(dirStmt)
                bind(dirStmt, 1, id); bind(dirStmt, 2, d.path); bind(dirStmt, 3, d.bytes); bind(dirStmt, 4, d.files)
                guard sqlite3_step(dirStmt) == SQLITE_DONE else { throw StoreError.sqlite(String(cString: sqlite3_errmsg(db))) }
            }

            let fileStmt = try prepare("INSERT INTO large_files(snapshot_id, path, bytes, modified) VALUES(?,?,?,?)")
            defer { sqlite3_finalize(fileStmt) }
            for f in r.largeFiles {
                sqlite3_reset(fileStmt)
                bind(fileStmt, 1, id); bind(fileStmt, 2, f.path); bind(fileStmt, 3, f.bytes)
                bind(fileStmt, 4, f.modified.timeIntervalSince1970)
                guard sqlite3_step(fileStmt) == SQLITE_DONE else { throw StoreError.sqlite(String(cString: sqlite3_errmsg(db))) }
            }
            try exec("COMMIT;")
            return id
        } catch {
            try? exec("ROLLBACK;")
            throw error
        }
    }

    public func snapshots(root: String? = nil) throws -> [Snapshot] {
        if let root {
            return try query("SELECT \(Store.snapshotColumns) FROM snapshots WHERE root = ? ORDER BY started_at", [root], row: Store.snapshot)
        }
        return try query("SELECT \(Store.snapshotColumns) FROM snapshots ORDER BY started_at", row: Store.snapshot)
    }

    public func latestSnapshot(root: String? = nil) throws -> Snapshot? {
        try snapshots(root: root).last
    }

    /// The newest snapshot taken at or before `date`, falling back to the oldest one available.
    public func snapshot(before date: Date, root: String, excluding id: Int64) throws -> Snapshot? {
        let all = try snapshots(root: root).filter { $0.id != id }
        return all.last(where: { $0.startedAt <= date }) ?? all.first
    }

    public func dirSizes(_ snapshotID: Int64) throws -> [String: Int64] {
        var out: [String: Int64] = [:]
        _ = try query("SELECT path, bytes FROM dir_sizes WHERE snapshot_id = ?", [snapshotID]) { s in
            out[Store.text(s, 0)] = sqlite3_column_int64(s, 1)
        }
        return out
    }

    public func dirEntries(_ snapshotID: Int64, nameSuffix: String) throws -> [DirEntry] {
        try query("SELECT path, bytes, files FROM dir_sizes WHERE snapshot_id = ? AND path LIKE ? ORDER BY bytes DESC",
                  [snapshotID, "%" + nameSuffix]) { s in
            DirEntry(path: Store.text(s, 0), bytes: sqlite3_column_int64(s, 1), files: sqlite3_column_int64(s, 2))
        }
    }

    public func largeFiles(_ snapshotID: Int64) throws -> [FileEntry] {
        try query("SELECT path, bytes, modified FROM large_files WHERE snapshot_id = ? ORDER BY bytes DESC", [snapshotID]) { s in
            FileEntry(path: Store.text(s, 0), bytes: sqlite3_column_int64(s, 1),
                      modified: Date(timeIntervalSince1970: sqlite3_column_double(s, 2)))
        }
    }

    /// Keeps every snapshot from the last 2 days, one per day for 30 days, then one per week.
    public func prune(now: Date = Date()) throws {
        let all = try snapshots()
        var keep = Set<Int64>()
        var seenBuckets = Set<String>()
        let cal = Calendar.current
        for s in all.reversed() {
            let age = now.timeIntervalSince(s.startedAt)
            let key: String
            if age < 2 * 86400 {
                keep.insert(s.id); continue
            } else if age < 30 * 86400 {
                key = "\(s.root)|d|\(cal.ordinality(of: .day, in: .era, for: s.startedAt) ?? 0)"
            } else {
                key = "\(s.root)|w|\(cal.component(.yearForWeekOfYear, from: s.startedAt))-\(cal.component(.weekOfYear, from: s.startedAt))"
            }
            if seenBuckets.insert(key).inserted { keep.insert(s.id) }
        }
        let drop = all.map(\.id).filter { !keep.contains($0) }
        guard !drop.isEmpty else { return }
        lock.lock(); defer { lock.unlock() }
        for id in drop {
            try run("DELETE FROM dir_sizes WHERE snapshot_id = ?", [id])
            try run("DELETE FROM large_files WHERE snapshot_id = ?", [id])
            try run("DELETE FROM snapshots WHERE id = ?", [id])
        }
        try run("DELETE FROM activity WHERE ts < ?", [now.addingTimeInterval(-30 * 86400).timeIntervalSince1970])
    }

    // MARK: - Live activity

    public func recordActivity(_ rows: [ActivityRow]) throws {
        guard !rows.isEmpty else { return }
        lock.lock(); defer { lock.unlock() }
        try exec("BEGIN;")
        do {
            for r in rows {
                try run("INSERT INTO activity(ts, bucket, owner, category, bytes, sample_path) VALUES(?,?,?,?,?,?)",
                        [r.time.timeIntervalSince1970, r.bucket, r.owner, r.category.rawValue, r.bytes, r.samplePath])
            }
            try exec("COMMIT;")
        } catch {
            try? exec("ROLLBACK;")
            throw error
        }
    }

    /// Live growth since `date`, summed per folder.
    public func activity(since date: Date) throws -> [ActivityRow] {
        try query("""
            SELECT MAX(ts), bucket, owner, category, SUM(bytes), sample_path
            FROM activity WHERE ts >= ? GROUP BY bucket ORDER BY SUM(bytes) DESC
            """, [date.timeIntervalSince1970]) { s in
            ActivityRow(time: Date(timeIntervalSince1970: sqlite3_column_double(s, 0)), bucket: Store.text(s, 1),
                        owner: Store.text(s, 2), category: Category(rawValue: Store.text(s, 3)) ?? .other,
                        bytes: sqlite3_column_int64(s, 4), samplePath: Store.text(s, 5))
        }
    }
}
